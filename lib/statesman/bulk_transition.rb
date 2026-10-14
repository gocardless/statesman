# frozen_string_literal: true

module Statesman
  # Bulk, race-safe state transitions for ActiveRecord (PostgreSQL, MySQL, SQLite).
  #
  # Statesman's Machine#transition_to! handles one parent at a time: a flip UPDATE on
  # the current `most_recent` transition, an INSERT for the new one, and (if the model
  # called configure_cached_current_state) an UPDATE on the parent's cached column -
  # each inside its own transaction, with guards/callbacks firing per record.
  #
  # BulkTransition performs the same mechanical write for many parents in a single
  # transaction: one `UPDATE ... RETURNING` to flip+lock the old rows (on adapters without
  # RETURNING: a `SELECT ... FOR UPDATE` then an `UPDATE`), one `insert_all!` for the new
  # ones, and one bulk cached_current_state UPDATE if configured. This trades
  # per-record guards/callbacks/AR-validations for an order-of-magnitude fewer round
  # trips on large batches.
  #
  # Deliberately NOT run: Machine guards, before/after/after_commit callbacks, and AR
  # validations/callbacks on the transition model. Callers that need equivalent side
  # effects must reproduce them, set-based, in the block passed to #call!.
  #
  # Like the single-transition path, "not current" is written as NULL when the
  # `most_recent` column is nullable (databases without partial indexes, e.g. MySQL, need
  # this for the unique (parent, most_recent) index) and false otherwise. On MySQL the
  # new rows are inserted "not current" and then marked current in a separate UPDATE, to
  # avoid the next-key locks an INSERT of `most_recent = true` takes (see
  # Statesman::Adapters::ActiveRecord#create_transition).
  #
  # Assumption (documented, not enforced): the transition table is not an STI table.
  #
  # A later version may add guard/callback execution (falling back to a plain per-item
  # #transition_to! loop where needed) - this is the proven,
  # independent mechanical core that such a version would sit on top of.
  class BulkTransition
    class ValidationError < StandardError; end

    SORT_KEY_INCREMENT = 10

    def initialize(model_class:, machine_class:, from:, to:)
      @model_class = model_class
      @from = from.to_s
      @to = to.to_s
      @transition_class = model_class.transition_class

      machine_class.validate_from_and_to_state(@from, @to)
    end

    # @param parent_ids [Array<String, Integer>] primary keys of the parents to
    #   transition. Parents not currently in `from` state are silently skipped - this
    #   is what makes the batch idempotent and safe to re-run.
    # @param metadata [Hash] applied uniformly to every new transition row in the batch,
    #   unless overridden per-parent by metadata_per_id.
    # @param attributes_to_copy [Array<String, Symbol>] extra transition-row columns to
    #   carry forward from the flipped row onto the new one, beyond the parent FK and
    #   sort_key, which are always carried. No default: the caller must explicitly audit
    #   which mutable columns their own after_transition callbacks depend on.
    # @param metadata_per_id [Hash{String, Integer => Hash}, nil] per-parent metadata
    #   overrides, keyed by parent id (matched by its string form, so 1 and "1" are the
    #   same parent), merged onto (and taking precedence over) the uniform `metadata` for
    #   that parent only. Parents absent from this hash just get the uniform `metadata`.
    # @param attributes_per_id [Hash{String, Integer => Hash}, nil] per-parent overrides,
    #   keyed like metadata_per_id, for attributes_to_copy columns only (anything else
    #   raises ValidationError), merged onto (and taking precedence over) the value
    #   carried forward from that parent's own flipped row - for a value that can't be
    #   derived from the previous transition (e.g. a value looked up from an
    #   association the caller already has loaded).
    # @param block [Proc, nil] optional, called with an ActiveRecord::Relation over the
    #   newly inserted transitions, inside the same transaction, after rows are flipped
    #   and inserted (and after the cached_current_state bulk update, if any). The
    #   relation is lazy: the block decides what to read (e.g. `pluck`) or write. An
    #   exception here rolls back the entire batch - nothing is committed.
    # @return [Array] parent ids that were actually transitioned.
    def call!(
      parent_ids, metadata: {}, attributes_to_copy: [],
      metadata_per_id: nil, attributes_per_id: nil, &block
    )
      return [] if parent_ids.empty?

      attributes_to_copy = attributes_to_copy.to_set(&:to_s)
      validate_attribute_names!(attributes_to_copy)
      metadata_per_id = normalize_per_id(metadata_per_id)
      attributes_per_id = normalize_per_id(attributes_per_id)
      validate_attributes_per_id!(attributes_per_id, attributes_to_copy)

      now = Time.current
      transitioned_ids = []

      ActiveRecord::Base.transaction(requires_new: true) do
        flipped_rows = flip_most_recent!(parent_ids, now, attributes_to_copy)
        next if flipped_rows.empty?

        primary_keys, transitioned_ids = insert_new_transitions!(
          flipped_rows, metadata, attributes_to_copy, now, metadata_per_id, attributes_per_id
        ).transpose
        inserted = transition_class.where(transition_class.primary_key => primary_keys)

        update_cached_current_state!(transitioned_ids)

        block&.call(inserted)
      end

      transitioned_ids
    end

    private

    attr_reader :model_class, :from, :to, :transition_class

    def mysql_gaplock_protection?
      Statesman.mysql_gaplock_protection?(transition_class.connection)
    end

    # Matches the single-transition path: NULL when the column is nullable (needed for a
    # unique (parent, most_recent) index on databases without partial indexes), else false.
    def not_most_recent_value
      transition_class.columns_hash["most_recent"].null == false ? false : nil
    end

    # PostgreSQL can flip and return rows in one `UPDATE ... RETURNING` statement and
    # recover inserted keys from `INSERT ... RETURNING`. Other adapters (MySQL, SQLite)
    # take a portable path built from `SELECT ... FOR UPDATE` + `UPDATE` by primary key.
    def returning_supported?
      transition_class.connection.adapter_name.casecmp("postgresql").zero?
    end

    def validate_attribute_names!(attributes_to_copy)
      unknown = attributes_to_copy - transition_class.column_names
      return if unknown.empty?

      raise ValidationError, "Unknown #{transition_class.name} column(s): #{unknown.join(', ')}"
    end

    # Overrides are matched against ids read back from the database, whose type (Integer,
    # String UUID) the caller needn't know - so both sides are compared as strings. Inner
    # keys become strings too, because the rows being inserted are string-keyed.
    def normalize_per_id(per_id)
      per_id&.to_h { |id, overrides| [id.to_s, overrides.transform_keys(&:to_s)] }
    end

    # Every row in one insert_all! must have the same keys, and an override for a column
    # that isn't carried forward would add a key to only some rows.
    def validate_attributes_per_id!(attributes_per_id, attributes_to_copy)
      return if attributes_per_id.nil?

      unknown = attributes_per_id.values.flat_map(&:keys).to_set - attributes_to_copy
      return if unknown.empty?

      raise ValidationError, "attributes_per_id column(s) not in attributes_to_copy: #{unknown.to_a.join(', ')}"
    end

    def parent_reflection
      @parent_reflection ||= Statesman::Adapters::ActiveRecordQueries.
        transition_reflection_for(model_class, transition_class)
    end

    def parent_foreign_key
      @parent_foreign_key ||= parent_reflection.foreign_key
    end

    def parent_primary_key
      @parent_primary_key ||= parent_reflection.active_record_primary_key
    end

    # Flips the `from`-state transitions to not-most-recent, returning the flipped
    # rows (including their pre-flip sort_key) via RETURNING. Under Postgres Read
    # Committed, a concurrent writer that commits a transition on one of these parents
    # between this statement starting and acquiring its row lock causes the WHERE
    # clause to re-evaluate against the latest committed row on wake - so that parent
    # is silently excluded here, never corrupted.
    def flip_most_recent!(parent_ids, now, attributes_to_copy)
      if returning_supported?
        flip_with_returning!(parent_ids, now, attributes_to_copy)
      else
        flip_with_lock!(parent_ids, now, attributes_to_copy)
      end
    end

    def flip_with_returning!(parent_ids, now, attributes_to_copy)
      # Not `RETURNING *`: only the carried columns are used afterwards, and a wider
      # result set is costly on large batches.
      returning = carried_columns(attributes_to_copy).
        map { |column| transition_class.connection.quote_column_name(column) }.
        join(", ")

      # Arel has no RETURNING support, so that one clause is appended to the compiled
      # statement; everything else (quoting, binds, IN list) is built by Arel.
      sql = "#{flip_update_manager(parent_ids, now).to_sql} RETURNING #{returning}"

      transition_class.connection.exec_query(sql).to_a
    end

    def flip_update_manager(parent_ids, now)
      table = transition_class.arel_table

      Arel::UpdateManager.new.tap do |update|
        update.table(table)
        update.set([[table[:most_recent], not_most_recent_value], [table[:updated_at], now]])
        update.where(
          table[:to_state].eq(from).
            and(table[:most_recent].eq(true)).
            and(table[parent_foreign_key].in(parent_ids)),
        )
      end
    end

    # Portable equivalent of the above: lock the matching rows, then flip them by primary
    # key. The locking read always sees the latest committed row (MySQL REPEATABLE READ
    # included), so a parent that a concurrent writer already moved on is excluded. SQLite
    # has no row locks, but serialises writers at the database level.
    def flip_with_lock!(parent_ids, now, attributes_to_copy)
      columns = carried_columns(attributes_to_copy)
      primary_key = transition_class.primary_key

      locked = transition_class.
        where(to_state: from, most_recent: true, parent_foreign_key => parent_ids).
        lock.
        pluck(primary_key, *columns)
      return [] if locked.empty?

      transition_class.where(primary_key => locked.map(&:first)).
        update_all(most_recent: not_most_recent_value, updated_at: now)

      locked.map { |_pk, *values| columns.zip(values).to_h }
    end

    def carried_columns(attributes_to_copy)
      Set[parent_foreign_key, "sort_key"] | attributes_to_copy
    end

    def insert_new_transitions!(
      flipped_rows, metadata, attributes_to_copy, now, metadata_per_id, attributes_per_id
    )
      carried = carried_columns(attributes_to_copy)
      include_from_state = transition_class.has_attribute?(:from_state)
      most_recent = mysql_gaplock_protection? ? not_most_recent_value : true

      rows = flipped_rows.map do |row|
        id = row[parent_foreign_key]
        row_metadata = merge_per_id(metadata, metadata_per_id, id)
        row_overrides = merge_per_id({}, attributes_per_id, id)

        new_row = row.slice(*carried).merge(row_overrides).merge(
          "to_state" => to,
          "metadata" => row_metadata,
          "most_recent" => most_recent,
          "sort_key" => row["sort_key"].to_i + SORT_KEY_INCREMENT,
          "created_at" => now,
          "updated_at" => now,
        )
        new_row["from_state"] = from if include_from_state
        new_row
      end

      insert_rows!(rows)
    rescue ActiveRecord::RecordNotUnique => e
      # One conflicting row aborts the whole batch - this is an accepted trade-off,
      # not a silent gap: every real writer (Statesman's own single-transition path, and
      # this class) follows the flip-then-insert convention, so a collision here means
      # something outside that convention wrote a most_recent row directly.
      raise TransitionConflictError, e.message
    end

    # Inserts the rows and returns [primary key, parent foreign key] pairs for them, so the
    # caller can both build a relation and know which parents moved without another query.
    # Under MySQL gap-lock protection the rows are also marked most recent here, so
    # whatever reads them afterwards sees the final state.
    def insert_rows!(rows)
      inserted = insert_and_fetch_keys!(rows)
      mark_most_recent!(inserted.map(&:first)) if mysql_gaplock_protection?
      inserted
    end

    def insert_and_fetch_keys!(rows)
      if returning_supported?
        return transition_class.insert_all!(rows, returning: [transition_class.primary_key, parent_foreign_key]).rows
      end

      transition_class.insert_all!(rows)
      fetch_inserted_keys(rows)
    end

    # Finds the rows just inserted by (parent, sort_key): the unique index Statesman
    # requires on those columns makes that pair unambiguous, whatever state the rows are in.
    def fetch_inserted_keys(inserted)
      sort_keys = inserted.map { |row| row["sort_key"] }.uniq
      expected = inserted.to_set { |row| [row[parent_foreign_key], row["sort_key"]] }

      transition_class.
        where(parent_foreign_key => inserted.map { |row| row[parent_foreign_key] }, sort_key: sort_keys).
        pluck(transition_class.primary_key, parent_foreign_key, "sort_key").
        select { |_pk, fk, sort_key| expected.include?([fk, sort_key]) }.
        map { |pk, fk, _sort_key| [pk, fk] }
    end

    # Second half of the MySQL gap-lock protection: the old rows were already flipped, so
    # this only ever sets one row per parent to true and cannot trip the unique index.
    def mark_most_recent!(primary_keys)
      transition_class.where(transition_class.primary_key => primary_keys).
        update_all(most_recent: true)
    end

    # Merges a per-parent override hash (see normalize_per_id) onto a base hash, for one
    # parent only. The override, where present, wins key-by-key.
    def merge_per_id(base, per_id, id)
      return base if per_id.nil? || !per_id.key?(id.to_s)

      base.merge(per_id.fetch(id.to_s))
    end

    def update_cached_current_state!(transitioned_ids)
      return if transitioned_ids.empty?
      return unless model_class.respond_to?(:cached_state_column_name)

      column = model_class.cached_state_column_name
      attrs = { column => to }
      attrs[:updated_at] = Time.current if model_class.cached_current_state_touch_updated_at?

      model_class.where(parent_primary_key => transitioned_ids).update_all(attrs)
    end
  end
end
