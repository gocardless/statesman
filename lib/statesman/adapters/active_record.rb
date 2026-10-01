# frozen_string_literal: true

require_relative "../exceptions"
require_relative "../bulk_transition"

module Statesman
  module Adapters
    class ActiveRecord
      JSON_COLUMN_TYPES = %w[json jsonb].freeze

      # Bounds the RecordNotUnique retry in .write_chunk — see the rescue there. Each
      # retry's own pre-insert recheck should always have excluded the previous attempt's
      # racer, so more than a couple of attempts means something is persistently wrong
      # rather than an ordinary transient race.
      MAX_INSERT_ATTEMPTS = 3

      # Rails recognises both the modern (created_at/updated_at) and legacy
      # (created_on/updated_on) timestamp column names for auto-timestamping — see
      # ActiveRecordTransition's own `updated_on` column, used elsewhere in this gem's
      # test suite to exercise the customisable updated_timestamp_column setting. Used by
      # .insert_survivors! to exclude them from a batched insert and let insert_all!'s own
      # record_timestamps: true populate them instead.
      TIMESTAMP_COLUMNS = %w[created_at created_on updated_at updated_on].freeze

      def self.database_supports_partial_indexes?(model)
        # Rails 3 doesn't implement `supports_partial_index?`
        if model.connection.respond_to?(:supports_partial_index?)
          model.connection.supports_partial_index?
        else
          model.connection.adapter_name.casecmp("postgresql").zero?
        end
      end

      # The batched write path behind Statesman::BulkTransition.call. `items` is an
      # Enumerable of { object:, adapter:, transition:, machine: }, all sharing one
      # bucket's `from` state (see BulkTransition.transition_batch) — `adapter` is that
      # item's own per-parent Adapters::ActiveRecord instance, `transition` was already
      # built via #build_transition (and had `before` run on it) by the caller.
      #
      # `after`/`after_commit` are per-item callables built by the orchestrator
      # (Statesman::BulkTransition#persist) — invoked here, not by the orchestrator,
      # because only this adapter knows when that's correct relative to its own
      # transaction: `after` runs *inside* the write transaction (a raise rolls back the
      # whole chunk, matching single-object semantics), and `after_commit` is registered
      # on the connection *before* that transaction closes, so — like the single-object
      # path's #add_after_commit_callback — it only actually fires once the *real*
      # outermost transaction commits, correctly deferring even when
      # Statesman::BulkTransition.call runs inside a caller-managed transaction.
      #
      # Phase A (no write transaction): read each parent's current most_recent row
      # (id/sort_key/to_state) in one query. A row whose to_state no longer matches
      # `from` is a stale read — the in-memory current_state check upstream in
      # Machine.validate_bulk_transition raced with a concurrent writer — and becomes a
      # :conflict immediately, before any write is attempted (see H2 in the design doc).
      #
      # Phase B (inside one transaction(requires_new: true)): flip most_recent false for
      # the has-history survivors' old rows, scoped to the ids read in Phase A, then
      # re-run Phase A's own read (.most_recent_rows_for) for every survivor's parent —
      # has-history or not. An honest, unraced flip leaves *no* most_recent row for that
      # parent (we haven't inserted the new one yet); a no-history parent never had one.
      # So *any* parent this re-read still finds a row for has raced — either a
      # concurrent writer's new row (it beat our flip, or inserted the parent's first-ever
      # transition) or, in the rare case our own flip simply hadn't run yet, a row that's
      # about to be contested — and becomes a :conflict, excluded from the insert. This
      # needs no RETURNING and no pessimistic locking (see .flip_most_recent for why the
      # row lock alone is enough), and is identical on Postgres/MySQL/SQLite. insert_all
      # persists the rest in one statement; a RecordNotUnique escaping that (the one
      # residual race window between the re-read above and the INSERT statement itself)
      # is handled by retrying the *whole* chunk, with the same survivors, outside this
      # transaction — see the rescue below for why, both for where it must sit and why it
      # doesn't need to work out who caused it.
      def self.bulk_create(items, from:, after:, after_commit:)
        return BulkTransition::Result.new if items.empty?

        representative = items.first[:adapter]
        transition_class = representative.transition_class
        assert_uniform_transition_class!(items)

        parent_ids = items.map { |item| item[:adapter].parent_model.id }
        current_rows = most_recent_rows_for(representative, parent_ids)
        survivors, failed = partition_by_staleness(items, current_rows, from)

        result = write_chunk(transition_class, representative, survivors, current_rows, after, after_commit)
        BulkTransition::Result.new(successful: result.successful, failed: failed + result.failed)
      end

      class << self
        private

        def assert_uniform_transition_class!(items)
          classes = items.map { |item| item[:adapter].transition_class }.uniq
          return if classes.one?

          raise ArgumentError, "BulkTransition requires every object to use the same " \
                               "transition class, got: #{classes.join(', ')}"
        end

        def partition_by_staleness(items, current_rows, from)
          from = from.to_s
          survivors = []
          failed = []

          items.each do |item|
            row = current_rows[item[:adapter].parent_model.id]

            if row.nil? || row[:to_state] == from
              survivors << item
            else
              failed << BulkTransition::Result::FailedItem.new(object: item[:object], reason: :conflict)
            end
          end

          [survivors, failed]
        end

        # One query, up front: every surviving parent's current most_recent row — its id
        # (the optimistic-concurrency token checked in Phase B), sort_key (the new
        # transition's basis), and to_state (the authoritative from_state, per H2 in the
        # design doc). A parent absent from the result has no history yet.
        def most_recent_rows_for(adapter, parent_ids, columns: %i[id sort_key to_state])
          return {} if parent_ids.empty?

          fk = adapter.send(:parent_join_foreign_key)
          scope = adapter.transition_class.where(adapter.send(:most_recent_transitions, nil, parent_ids))

          scope.pluck(fk, *columns).each_with_object({}) do |row, hash|
            parent_id, *values = row
            hash[parent_id] = columns.zip(values).to_h
          end
        end

        # Runs the full flip -> recheck -> insert -> hydrate -> cached-state -> callback
        # sequence for one chunk, inside one transaction. Retries, outside that
        # transaction, if the final insert hits the one residual race window the recheck
        # can't close — see the RecordNotUnique rescue below.
        def write_chunk(transition_class, representative, survivors, current_rows, after, after_commit, attempt: 1)
          return BulkTransition::Result.new if survivors.empty?

          assign_sort_keys!(survivors, current_rows)
          successful = []
          failed = []

          begin
            transition_class.transaction(requires_new: true) do
              writable, raced = flip_and_partition(transition_class, representative, survivors, current_rows)
              failed.concat(raced)
              next if writable.empty?

              persist_writable!(transition_class, representative, writable, after, after_commit)
              successful.concat(writable.map { |item| item[:object] })
            end
          rescue ::ActiveRecord::RecordNotUnique
            raise if attempt >= MAX_INSERT_ATTEMPTS

            # This must be rescued *outside* the transaction(requires_new: true) block,
            # not around insert_all within it: on Postgres, a statement error leaves that
            # transaction/savepoint aborted until it's rolled back, and only letting the
            # error escape the `transaction do...end` block gets Rails to do that rollback
            # cleanly — rescuing inside would leave the connection unusable for anything
            # that follows. Retrying the *whole* chunk with the *same* survivor set (not a
            # pre-filtered one) is deliberate, not wasteful: the retry's own flip + recheck
            # above re-discovers whoever just raced — their row is now actually committed
            # and visible — and correctly excludes them before the next insert attempt, so
            # there's no need to parse the exception to work out who caused it.
            retried = write_chunk(transition_class, representative, survivors, current_rows, after, after_commit,
                                  attempt: attempt + 1)
            successful.concat(retried.successful)
            failed.concat(retried.failed)
          end

          BulkTransition::Result.new(successful: successful, failed: failed)
        end

        # Flips most_recent for the has-history survivors' old rows, then re-reads every
        # survivor's parent (see .most_recent_rows_for) to find out who raced — see
        # .write_chunk's own comment and .flip_most_recent for the detection mechanism.
        def flip_and_partition(transition_class, representative, survivors, current_rows)
          flip_ids = survivors.filter_map { |item| current_rows.dig(item[:adapter].parent_model.id, :id) }
          flip_most_recent(transition_class, representative, flip_ids)

          parent_ids = survivors.map { |item| item[:adapter].parent_model.id }
          raced_rows = most_recent_rows_for(representative, parent_ids)

          writable, raced = survivors.partition { |item| !raced_rows.key?(item[:adapter].parent_model.id) }
          failed = raced.map { |item| BulkTransition::Result::FailedItem.new(object: item[:object], reason: :conflict) }
          [writable, failed]
        end

        # Persists the survivors of .flip_and_partition: insert, batched cached-state
        # write, then per-item `after` (inside this still-open transaction — a raise rolls
        # it back) and a registered, deferred `after_commit` per item.
        def persist_writable!(transition_class, representative, writable, after, after_commit)
          insert_survivors!(transition_class, representative, writable)
          maintain_cached_current_state_batch(representative, writable, writable.first[:transition].to_state)

          writable.each do |item|
            after.call(item)
            transition_class.connection.add_transaction_record(
              ActiveRecordAfterCommitWrap.new(transition_class.connection) { after_commit.call(item) },
            )
          end
        end

        def assign_sort_keys!(survivors, current_rows)
          survivors.each do |item|
            base_sort_key = current_rows.dig(item[:adapter].parent_model.id, :sort_key)
            item[:transition].assign_attributes(
              sort_key: base_sort_key ? base_sort_key + 10 : 10,
              most_recent: true,
            )
          end
        end

        # Flips most_recent false for the given ids, scoped to the Phase-A-captured
        # tokens. Needs no RETURNING and no pessimistic locking to be safe: the UPDATE
        # itself takes a row lock on every id it actually matches, so a concurrent writer
        # targeting the same parent physically blocks on that lock until our transaction
        # ends. Whether a given id ends up flipped by us, or was already flipped away by a
        # racer before we got here, it's false either way afterward — which is exactly why
        # race detection isn't done by re-querying these ids (that can't distinguish the
        # two cases), but by the separate, unambiguous .most_recent_rows_for re-read in
        # .write_chunk: an honest, unraced flip leaves no most_recent row for that parent
        # at all until the insert that follows.
        def flip_most_recent(transition_class, representative, ids)
          return if ids.empty?

          set_attrs = { most_recent: representative.send(:not_most_recent_value, db_cast: false) }
          column, timestamp = representative.send(:updated_column_and_timestamp)
          set_attrs[column] = timestamp if column

          transition_class.where(id: ids, most_recent: true).update_all(set_attrs)
        end

        # Excludes "id" (let the DB generate it) and any timestamp columns (let
        # insert_all!'s own record_timestamps: true populate them, matching what #save!
        # would do for the single-object path — items built via #build_transition carry
        # these as explicit nil keys, which would otherwise suppress insert_all!'s
        # auto-timestamping and insert literal NULLs).
        #
        # Deliberately insert_all! (bang), not insert_all: the plain, non-bang insert_all
        # silently does ON CONFLICT DO NOTHING — it never raises on a unique violation, it
        # just drops the conflicting row and returns fewer rows than requested. That would
        # both violate "survivors commit atomically per chunk" (silently discarding a row
        # that should have been a loud :conflict) and mean the RecordNotUnique rescue
        # around .write_chunk's whole insert-and-retry sequence is dead code. insert_all!
        # raises, matching #save!'s own behaviour on the single-object path.
        def insert_survivors!(transition_class, representative, writable)
          timestamp_columns = TIMESTAMP_COLUMNS & transition_class.column_names
          insert_attrs = writable.map { |item| item[:transition].attributes.except("id", *timestamp_columns) }

          if transition_class.connection.supports_insert_returning?
            result = transition_class.insert_all!(insert_attrs, returning: transition_class.column_names,
                                                                record_timestamps: true)
            rows_by_parent_id = index_rows_by_parent_id(result.to_a, representative)
          else
            transition_class.insert_all!(insert_attrs, record_timestamps: true)
            rows_by_parent_id = reselect_rows_by_parent_id(transition_class, representative, writable)
          end

          hydrate!(writable, rows_by_parent_id)
        end

        def index_rows_by_parent_id(rows, representative)
          fk = representative.send(:parent_join_foreign_key)
          rows.to_h { |row| [row[fk], row] }
        end

        # MySQL has no insert_all RETURNING support — re-read the rows we just inserted
        # instead. Safe inside our still-open transaction: has-history parents are lock-
        # protected and no-history parents were just verified-then-inserted here, so
        # nothing else can be writing a competing transition for any of these parents
        # right now.
        def reselect_rows_by_parent_id(transition_class, representative, writable)
          fk = representative.send(:parent_join_foreign_key)
          parent_ids = writable.map { |item| item[:adapter].parent_model.id }

          transition_class.where(representative.send(:most_recent_transitions, nil, parent_ids)).
            to_h { |record| [record[fk], record.attributes] }
        end

        # Merges the recovered, persisted row (id, timestamps, final sort_key/
        # most_recent) onto the already-`before`-mutated in-memory attributes — not the
        # recovered row alone, so a `before` callback's mutation (e.g. custom metadata)
        # survives — then rebuilds a real, persisted-looking record via .instantiate: the
        # idiomatic Rails way to materialize a row without re-running
        # validations/callbacks/save!.
        def hydrate!(writable, rows_by_parent_id)
          writable.each do |item|
            row = rows_by_parent_id.fetch(item[:adapter].parent_model.id)
            merged = item[:transition].attributes.merge(row)
            item[:transition] = item[:transition].class.instantiate(merged)
          end
        end

        # Batched generalization of #maintain_cached_current_state: one UPDATE for every
        # written parent, since the target state is homogeneous across the whole chunk.
        def maintain_cached_current_state_batch(representative, writable, to_state)
          model_class = representative.parent_model.class
          return unless model_class.respond_to?(:cached_state_column_name)

          column = model_class.cached_state_column_name
          unless model_class.column_names.include?(column.to_s)
            raise ArgumentError,
                  "cache_current_state_column: #{column.inspect} is not a column " \
                  "on #{model_class.name}"
          end

          attributes = { column => to_state }
          attributes[:updated_at] = Time.current if model_class.cached_current_state_touch_updated_at?
          parent_ids = writable.map { |item| item[:adapter].parent_model.id }
          model_class.where(id: parent_ids).update_all(attributes)
        end
      end

      def initialize(transition_class, parent_model, observer, options = {})
        serialized = serialized?(transition_class)
        column_type = transition_class.columns_hash["metadata"].sql_type
        if !serialized && !JSON_COLUMN_TYPES.include?(column_type)
          raise UnserializedMetadataError, transition_class.name
        elsif serialized && JSON_COLUMN_TYPES.include?(column_type)
          raise IncompatibleSerializationError, transition_class.name
        end

        @transition_class = transition_class
        @transition_table = transition_class.arel_table
        @parent_model = parent_model
        @observer = observer
        @association_name =
          options[:association_name] || @transition_class.table_name
      end

      attr_reader :transition_class, :transition_table, :parent_model

      def create(from, to, metadata = {})
        create_transition(from.to_s, to.to_s, metadata)
      rescue ::ActiveRecord::RecordNotUnique => e
        if transition_conflict_error? e
          # The history has the invalid transition on the end of it, which means
          # `current_state` would then be incorrect. We force a reload of the history to
          # avoid this.
          transitions_for_parent.reload
          raise TransitionConflictError, e.message
        end

        raise
      ensure
        reset
      end

      # Builds an unsaved transition, with no callbacks run — the counterpart to
      # Adapters::Memory#build_transition, used by Statesman::BulkTransition's write path.
      #
      # Deliberately does not set `sort_key` (unlike #default_transition_attributes, used
      # by the single-object #create_transition, which always calls #next_sort_key). This
      # method is called once per object, *before* any batching happens — if it queried for
      # the current sort key itself, that would be one query per object again, defeating
      # the entire point of batching before a single row is even persisted.
      # Adapters::ActiveRecord.bulk_create computes every survivor's real `sort_key` from
      # one batched read instead (see #most_recent_rows_for), and assigns it there.
      def build_transition(from, to, metadata = {})
        attributes = {
          to_state: to.to_s,
          metadata: metadata,
          most_recent: not_most_recent_value(db_cast: false),
        }
        attributes[:from_state] = from.to_s if @transition_class.has_attribute?(:from_state)

        transitions_for_parent.build(attributes)
      end

      def history(force_reload: false)
        if transitions_for_parent.loaded? && !force_reload
          # Workaround for Rails bug which causes infinite loop when sorting
          # already loaded result set. Introduced in rails/rails@b097ebe
          transitions_for_parent.to_a.sort_by(&:sort_key)
        else
          transitions_for_parent.order(:sort_key)
        end
      end

      def last(force_reload: false)
        if force_reload
          @last_transition = history(force_reload: true).last
        elsif instance_variable_defined?(:@last_transition)
          @last_transition
        else
          @last_transition = history.last
        end
      end

      def reset
        if instance_variable_defined?(:@last_transition)
          remove_instance_variable(:@last_transition)
        end
      end

      private

      def create_transition(from, to, metadata)
        transition = transitions_for_parent.build(
          default_transition_attributes(from, to, metadata),
        )

        transition_class.transaction(requires_new: true) do
          @observer.execute(:before, from, to, transition)

          if mysql_gaplock_protection?(transition_class.connection)
            # We save the transition first with most_recent falsy, then mark most_recent
            # true after to avoid letting MySQL acquire a next-key lock which can cause
            # deadlocks.
            #
            # To avoid an additional query, we manually adjust the most_recent attribute
            # on our transition assuming that update_most_recents will have set it to true

            transition.save!

            unless update_most_recents(transition.id).positive?
              raise ActiveRecord::Rollback, "failed to update most_recent"
            end

            transition.assign_attributes(most_recent: true)
          else
            update_most_recents
            transition.assign_attributes(most_recent: true)
            transition.save!
          end

          maintain_cached_current_state(transition)

          @last_transition = transition
          @observer.execute(:after, from, to, transition)
          add_after_commit_callback(from, to, transition)
        end

        transition
      end

      # Writes the cached current state column configured via
      # Statesman::Adapters::ConfigureCachedCurrentState#configure_cached_current_state,
      # if the parent model opted in. Done here, rather than via an ActiveRecord
      # callback on transition_class, so it fires reliably even under
      # mysql_gaplock_protection - where most_recent is flipped to true via a raw SQL
      # UPDATE that bypasses ActiveRecord callbacks entirely (see above). This method
      # always runs after most_recent has been set on `transition` (in both branches
      # above), and before the machine's own after_transition callbacks are invoked.
      def maintain_cached_current_state(transition)
        model_class = parent_model.class
        return unless model_class.respond_to?(:cached_state_column_name)

        column = model_class.cached_state_column_name
        unless model_class.column_names.include?(column.to_s)
          raise ArgumentError,
                "cache_current_state_column: #{column.inspect} is not a column " \
                "on #{model_class.name}"
        end

        attributes = { column => transition.to_state }
        attributes[:updated_at] = Time.current if model_class.cached_current_state_touch_updated_at?
        parent_model.update_columns(attributes)
      end

      def default_transition_attributes(from, to, metadata)
        attributes = {
          to_state: to,
          sort_key: next_sort_key,
          metadata: metadata,
          most_recent: not_most_recent_value(db_cast: false),
        }

        if @transition_class.has_attribute?(:from_state)
          attributes[:from_state] = from
        end

        attributes
      end

      def add_after_commit_callback(from, to, transition)
        transition_class.connection.add_transaction_record(
          ActiveRecordAfterCommitWrap.new(transition_class.connection) do
            @observer.execute(:after_commit, from, to, transition)
          end,
        )
      end

      def transitions_for_parent
        parent_model.send(@association_name)
      end

      # Sets the given transition most_recent = t while unsetting the most_recent of any
      # previous transitions.
      def update_most_recents(most_recent_id = nil)
        update = build_arel_manager(::Arel::UpdateManager, transition_class)
        update.table(transition_table)
        update.where(most_recent_transitions(most_recent_id))
        update.set(build_most_recents_update_all_values(most_recent_id))

        # MySQL will validate index constraints across the intermediate result of an
        # update. This means we must order our update to deactivate the previous
        # most_recent before setting the new row to be true.
        if mysql_gaplock_protection?(transition_class.connection)
          update.order(transition_table[:most_recent].desc)
        end

        transition_class.connection.update(update.to_sql(transition_class))
      end

      # `parent_id` accepts either a single id (the single-object write path) or an Array
      # of ids (Adapters::ActiveRecord.bulk_create's batched reads/writes, scoped to many
      # parents at once) — `Arel::Nodes::Node#in` vs `#eq` handles the distinction.
      # `most_recent_id`, by contrast, is always a single id: it's the single-object flip's
      # own CASE-WHEN token (see #build_most_recents_update_all_values) and has no batched
      # equivalent — bulk_create's flip is a separate, simpler statement (see
      # .flip_most_recent) that doesn't need it.
      def most_recent_transitions(most_recent_id = nil, parent_id = parent_model.id)
        if most_recent_id
          concrete_transitions_of_parent(parent_id).and(
            transition_table[:id].eq(most_recent_id).or(
              transition_table[:most_recent].eq(true),
            ),
          )
        else
          concrete_transitions_of_parent(parent_id).and(transition_table[:most_recent].eq(true))
        end
      end

      def concrete_transitions_of_parent(parent_id = parent_model.id)
        if transition_sti?
          transitions_of_parent(parent_id).and(
            transition_table[transition_class.inheritance_column].
              eq(transition_class.name),
          )
        else
          transitions_of_parent(parent_id)
        end
      end

      def transitions_of_parent(parent_id = parent_model.id)
        column = transition_table[parent_join_foreign_key.to_sym]
        parent_id.is_a?(Array) ? column.in(parent_id) : column.eq(parent_id)
      end

      # Generates update_all Arel values that will touch the updated timestamp (if valid
      # for this model) and set most_recent to true only for the transition with a
      # matching most_recent ID.
      #
      # This is quite nasty, but combines two updates (set all most_recent = f, set
      # current most_recent = t) into one, which helps improve transition performance
      # especially when database latency is significant.
      #
      # The SQL this can help produce looks like:
      #
      #   update transitions
      #      set most_recent = (case when id = 'PA123' then TRUE else FALSE end)
      #        , updated_at = '...'
      #      ...
      #
      def build_most_recents_update_all_values(most_recent_id = nil)
        [
          [
            transition_table[:most_recent],
            Arel::Nodes::SqlLiteral.new(most_recent_value(most_recent_id)),
          ],
        ].tap do |values|
          # Only if we support the updated at timestamps should we add this column to the
          # update
          updated_column, updated_at = updated_column_and_timestamp

          if updated_column
            values << [
              transition_table[updated_column.to_sym],
              updated_at,
            ]
          end
        end
      end

      def most_recent_value(most_recent_id)
        if most_recent_id
          Arel::Nodes::Case.new.
            when(transition_table[:id].eq(most_recent_id)).then(db_true).
            else(not_most_recent_value).to_sql(transition_class)
        else
          Arel::Nodes::SqlLiteral.new(not_most_recent_value)
        end
      end

      # Provide a wrapper for constructing an update manager which handles a breaking API
      # change in Arel as we move into Rails >6.0.
      #
      # https://github.com/rails/rails/commit/7508284800f67b4611c767bff9eae7045674b66f
      def build_arel_manager(manager, engine)
        if manager.instance_method(:initialize).arity.zero?
          manager.new
        else
          manager.new(engine)
        end
      end

      def next_sort_key
        (last && (last.sort_key + 10)) || 10
      end

      def serialized?(transition_class)
        transition_class.type_for_attribute("metadata").
          is_a?(::ActiveRecord::Type::Serialized)
      end

      def transition_conflict_error?(err)
        return true if unique_indexes.any? { |i| err.message.include?(i.name) }

        err.message.include?(transition_class.table_name) &&
          (err.message.include?("sort_key") || err.message.include?("most_recent"))
      end

      def unique_indexes
        transition_class.connection.
          indexes(transition_class.table_name).
          select do |index|
            next unless index.unique

            # We care about the columns used in the index, but not necessarily
            # the order, which is why we sort both sides of the comparison here
            index.columns.sort == [parent_join_foreign_key, "sort_key"].sort ||
              index.columns.sort == [parent_join_foreign_key, "most_recent"].sort
          end
      end

      def transition_sti?
        transition_class.column_names.include?(transition_class.inheritance_column)
      end

      def parent_association
        parent_model.class.
          reflect_on_all_associations(:has_many).
          find { |r| r.name.to_s == @association_name.to_s }
      end

      def parent_join_foreign_key
        association_join_primary_key(parent_association)
      end

      def association_join_primary_key(association)
        if association.respond_to?(:join_primary_key)
          association.join_primary_key
        elsif association.method(:join_keys).arity.zero?
          # Support for Rails 5.1
          association.join_keys.key
        else
          # Support for Rails < 5.1
          association.join_keys(transition_class).key
        end
      end

      # updated_column_and_timestamp should return [column_name, value]
      def updated_column_and_timestamp
        # TODO: Once we've set expectations that transition classes should conform to
        # the interface of Adapters::ActiveRecordTransition as a breaking change in the
        # next major version, we can stop calling `#respond_to?` first and instead
        # assume that there is a `.updated_timestamp_column` method we can call.
        #
        # At the moment, most transition classes will include the module, but not all,
        # not least because it doesn't work with PostgreSQL JSON columns for metadata.
        column = if transition_class.respond_to?(:updated_timestamp_column)
                   transition_class.updated_timestamp_column
                 else
                   ActiveRecordTransition::DEFAULT_UPDATED_TIMESTAMP_COLUMN
                 end

        # No updated timestamp column, don't return anything
        return nil if column.nil?

        [
          column, default_timezone == :utc ? Time.now.utc : Time.now
        ]
      end

      def default_timezone
        # Rails 7 deprecates ActiveRecord::Base.default_timezone
        # in favour of ActiveRecord.default_timezone
        if ::ActiveRecord.respond_to?(:default_timezone)
          return ::ActiveRecord.default_timezone
        end

        ::ActiveRecord::Base.default_timezone
      end

      def mysql_gaplock_protection?(connection)
        Statesman.mysql_gaplock_protection?(connection)
      end

      def db_true
        transition_class.connection.quote(type_cast(true))
      end

      def db_false
        transition_class.connection.quote(type_cast(false))
      end

      def db_null
        Arel::Nodes::SqlLiteral.new("NULL")
      end

      # Type casting against a column is deprecated and will be removed in Rails 6.2.
      # See https://github.com/rails/arel/commit/6160bfbda1d1781c3b08a33ec4955f170e95be11
      def type_cast(value)
        transition_class.connection.type_cast(value)
      end

      # Check whether the `most_recent` column allows null values. If it doesn't, set old
      # records to `false`, otherwise, set them to `NULL`.
      #
      # Some conditioning here is required to support databases that don't support partial
      # indexes. By doing the conditioning on the column, rather than Rails' opinion of
      # whether the database supports partial indexes, we're robust to DBs later adding
      # support for partial indexes.
      def not_most_recent_value(db_cast: true)
        if transition_class.columns_hash["most_recent"].null == false
          return db_cast ? db_false : false
        end

        db_cast ? db_null : nil
      end
    end

    class ActiveRecordAfterCommitWrap
      def initialize(connection, &block)
        @callback = block
        @connection = connection
      end

      def self.trigger_transactional_callbacks?
        true
      end

      def trigger_transactional_callbacks?
        true
      end

      def has_transactional_callbacks?
        true
      end

      def committed!(*)
        @callback.call
      end

      def before_committed!(*); end

      def rolledback!(*); end

      # Required for +transaction(requires_new: true)+
      def add_to_transaction(*)
        @connection.add_transaction_record(self)
      end
    end
  end
end
