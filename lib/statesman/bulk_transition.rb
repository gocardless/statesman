# frozen_string_literal: true

module Statesman
  # MVP: bulk, race-safe state transitions for ActiveRecord + PostgreSQL.
  #
  # Statesman's Machine#transition_to! handles one parent at a time: a flip UPDATE on
  # the current `most_recent` transition, an INSERT for the new one, and (if the model
  # called configure_cached_current_state) an UPDATE on the parent's cached column -
  # each inside its own transaction, with guards/callbacks firing per record.
  #
  # BulkTransition performs the same mechanical write for many parents in a single
  # transaction: one `UPDATE ... RETURNING` to flip+lock the old rows, one `insert_all`
  # for the new ones, and one bulk cached_current_state UPDATE if configured. This
  # trades per-record guards/callbacks/AR-validations for an order-of-magnitude fewer
  # round trips on large batches.
  #
  # Deliberately NOT run: Machine guards, before/after/after_commit callbacks, and AR
  # validations/callbacks on the transition model. Callers that need equivalent side
  # effects must reproduce them, set-based, in the block passed to #call!.
  #
  # Assumptions (documented, not enforced beyond the Postgres check): the transition
  # table's `most_recent` column is NOT NULL (no mixed null/false "not current" rows),
  # and it is not an STI transition table.
  class BulkTransition
    class ValidationError < StandardError; end
    class UnsupportedAdapterError < StandardError; end

    SORT_KEY_INCREMENT = 10

    def initialize(model_class:, machine_class:, from:, to:)
      @model_class = model_class
      @from = from.to_s
      @to = to.to_s
      @transition_class = model_class.transition_class

      machine_class.validate_from_and_to_state(@from, @to)
      assert_postgres!
    end

    # @param parent_ids [Array<String, Integer>] primary keys of the parents to
    #   transition. Parents not currently in `from` state are silently skipped - this
    #   is what makes the batch idempotent and safe to re-run.
    # @param metadata [Hash] applied uniformly to every new transition row in the batch.
    # @param attributes_to_copy [Array<String, Symbol>] extra transition-row columns to
    #   carry forward from the flipped row onto the new one, beyond the parent FK and
    #   sort_key, which are always carried. No default: the caller must explicitly audit
    #   which mutable columns their own after_transition callbacks depend on.
    # @yield [inserted_rows] optional, runs inside the same transaction after rows are
    #   flipped and inserted (and after the cached_current_state bulk update, if any).
    #   An exception here rolls back the entire batch - nothing is committed.
    # @return [Array] parent ids that were actually transitioned.
    def call!(parent_ids, metadata: {}, attributes_to_copy: [])
      return [] if parent_ids.empty?

      attributes_to_copy = attributes_to_copy.map(&:to_s)
      validate_attribute_names!(attributes_to_copy)

      now = Time.current
      transitioned_ids = []

      ActiveRecord::Base.transaction(requires_new: true) do
        flipped_rows = flip_most_recent!(parent_ids, now)
        next if flipped_rows.empty?

        inserted_rows = insert_new_transitions!(flipped_rows, metadata, attributes_to_copy, now)
        transitioned_ids = inserted_rows.map { |row| row[parent_foreign_key] }

        update_cached_current_state!(transitioned_ids)

        yield(inserted_rows) if block_given?
      end

      transitioned_ids
    end

    private

    attr_reader :model_class, :from, :to, :transition_class

    def assert_postgres!
      adapter = transition_class.connection.adapter_name
      return if adapter.casecmp("postgresql").zero?

      raise UnsupportedAdapterError,
            "Statesman::BulkTransition only supports PostgreSQL today (got #{adapter})"
    end

    def validate_attribute_names!(attributes_to_copy)
      unknown = attributes_to_copy - transition_class.column_names
      return if unknown.empty?

      raise ValidationError, "Unknown #{transition_class.name} column(s): #{unknown.join(', ')}"
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

    # Flips the `from`-state transitions to most_recent: false, returning the flipped
    # rows (including their pre-flip sort_key) via RETURNING. Under Postgres Read
    # Committed, a concurrent writer that commits a transition on one of these parents
    # between this statement starting and acquiring its row lock causes the WHERE
    # clause to re-evaluate against the latest committed row on wake - so that parent
    # is silently excluded here, never corrupted.
    def flip_most_recent!(parent_ids, now)
      quoted_table = transition_class.quoted_table_name
      quoted_fk = transition_class.connection.quote_column_name(parent_foreign_key)

      sql = transition_class.sanitize_sql_array([
        <<~SQL.squish,
          UPDATE #{quoted_table}
          SET most_recent = false, updated_at = ?
          WHERE to_state = ?
            AND most_recent = true
            AND #{quoted_fk} IN (?)
          RETURNING *
        SQL
        now, from, parent_ids
      ])

      transition_class.connection.exec_query(sql).to_a
    end

    def insert_new_transitions!(flipped_rows, metadata, attributes_to_copy, now)
      carried_columns = ([parent_foreign_key, "sort_key"] + attributes_to_copy).uniq
      include_from_state = transition_class.has_attribute?(:from_state)

      rows = flipped_rows.map do |row|
        new_row = row.slice(*carried_columns).merge(
          "to_state" => to,
          "metadata" => metadata,
          "most_recent" => true,
          "sort_key" => row["sort_key"].to_i + SORT_KEY_INCREMENT,
          "created_at" => now,
          "updated_at" => now,
        )
        new_row["from_state"] = from if include_from_state
        new_row
      end

      returning_columns = (carried_columns + ["to_state"]).uniq
      transition_class.insert_all(rows, returning: returning_columns).to_a
    rescue ActiveRecord::RecordNotUnique => e
      # One conflicting row aborts the whole batch - this is an accepted MVP trade-off,
      # not a silent gap: every real writer (Statesman's own single-transition path, and
      # this class) follows the flip-then-insert convention, so a collision here means
      # something outside that convention wrote a most_recent row directly.
      raise TransitionConflictError, e.message
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
