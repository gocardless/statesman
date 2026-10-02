# frozen_string_literal: true

require_relative "../../bulk_transition"

module Statesman
  module Adapters
    class ActiveRecord
      # The real implementation behind Adapters::ActiveRecord.bulk_create — see that
      # method for the full contract (what `items`/`after`/`after_commit` are and why
      # `after`/`after_commit` are invoked here rather than by the orchestrator).
      #
      # One instance per call. #assert_uniform_adapter! derives transition_class/
      # parent_model_class/foreign_key once, validating they're uniform across every
      # item (not assumed from one representative item) — every private method below
      # reads those as plain instance state instead of having them threaded through as
      # parameters, or reaching into any one item's adapter instance.
      #
      # Mechanics, two steps:
      # 1. Snapshot read (no transaction yet): read each parent's current most_recent
      #    row in one query. If its to_state no longer matches `from`, a concurrent
      #    writer already moved that parent on — fail it as :conflict before
      #    attempting any write.
      # 2. Write transaction: flip most_recent false for the has-history survivors'
      #    old rows, then re-run the snapshot read for every survivor. An honest,
      #    unraced flip leaves no most_recent row for that parent until the insert
      #    that follows, so any parent the re-read still finds a row for has raced —
      #    exclude it as :conflict. This needs no RETURNING or locking: the flip
      #    UPDATE itself takes a row lock, so a concurrent writer on the same parent
      #    blocks until we commit or roll back. insert_all! persists the rest; if it
      #    still hits a RecordNotUnique (the one remaining race window, between the
      #    re-read and the INSERT), retry the whole chunk outside this transaction —
      #    see the rescue below.
      class BulkCreate
        # Bounds the RecordNotUnique retry in #write_chunk — see the rescue there. Each
        # retry's own pre-insert recheck should always have excluded the previous
        # attempt's racer, so more than a couple of attempts means something is
        # persistently wrong rather than an ordinary transient race.
        MAX_INSERT_ATTEMPTS = 3

        # Rails recognises both the modern (created_at/updated_at) and legacy
        # (created_on/updated_on) timestamp column names. Used by #insert_survivors! to
        # exclude them from a batched insert so insert_all!'s own record_timestamps:
        # true can populate them instead.
        TIMESTAMP_COLUMNS = %w[created_at created_on updated_at updated_on].freeze

        def self.call(items, from:, after:, after_commit:)
          new(items, from: from, after: after, after_commit: after_commit).call
        end

        def initialize(items, from:, after:, after_commit:)
          @items = items
          @from = from.to_s
          @after = after
          @after_commit = after_commit
        end

        def call
          return BulkTransition::Result.new if items.empty?

          assert_uniform_adapter!

          parent_ids = items.map { |item| item[:object].id }
          @current_rows = most_recent_rows_for(parent_ids)
          survivors, failed = partition_by_staleness

          result = write_chunk(survivors)
          BulkTransition::Result.new(successful: result.successful, failed: failed + result.failed)
        end

        private

        attr_reader :items, :from, :current_rows, :after, :after_commit,
                    :transition_class, :parent_model_class, :foreign_key

        # This batch's SQL is one shared set of mechanics (one snapshot query, one flip
        # UPDATE, one insert_all!) built from transition_class/parent_model_class/
        # association_name — it only produces correct SQL if every item agrees on all
        # three. They're per-Machine-*instance* options (see Machine#initialize), not
        # fixed per Machine subclass, so bucketing by machine class upstream (see
        # BulkTransition.transition_batch) doesn't already guarantee this — it has to be
        # checked for real, against every item, here.
        def assert_uniform_adapter!
          transition_classes = items.map { |item| item[:adapter].transition_class }.uniq
          parent_model_classes = items.map { |item| item[:object].class }.uniq
          association_names = items.map { |item| item[:adapter].association_name }.uniq

          assert_one!("transition class", transition_classes)
          assert_one!("parent model class", parent_model_classes)
          assert_one!("association name", association_names)

          @transition_class = transition_classes.first
          @parent_model_class = parent_model_classes.first
          @foreign_key = ActiveRecord.parent_join_foreign_key(@parent_model_class, association_names.first,
                                                              @transition_class)
        end

        def assert_one!(label, values)
          return if values.one?

          raise ArgumentError, "BulkTransition requires every object to use the same #{label}, " \
                               "got: #{values.join(', ')}"
        end

        # Machine.validate_bulk_transition's current_state check can already be stale
        # by the time this runs — it ran before the snapshot read. Re-check each
        # survivor's assumed `from` against the row actually read: a mismatch means a
        # concurrent writer already moved that parent on, so it fails as :conflict here,
        # before the write transaction even opens. A parent absent from `current_rows`
        # has no history yet and always survives.
        def partition_by_staleness
          survivors = []
          failed = []

          items.each do |item|
            row = current_rows[item[:object].id]

            if row.nil? || row[:to_state] == from
              survivors << item
            else
              failed << BulkTransition::Result::FailedItem.new(object: item[:object], reason: :conflict)
            end
          end

          [survivors, failed]
        end

        # Every surviving parent's current most_recent row, in one query: id (the
        # optimistic-concurrency token), sort_key (the new transition's basis), and
        # to_state (the authoritative from_state). A parent absent from the result has
        # no history yet.
        def most_recent_rows_for(parent_ids, columns: %i[id sort_key to_state])
          return {} if parent_ids.empty?

          scope = transition_class.where(ActiveRecord.most_recent_transitions(transition_class, foreign_key,
                                                                              parent_ids))

          scope.pluck(foreign_key, *columns).each_with_object({}) do |row, hash|
            parent_id, *values = row
            hash[parent_id] = columns.zip(values).to_h
          end
        end

        # Flip -> recheck -> insert -> hydrate -> cached-state -> callbacks, for one
        # chunk, inside one transaction. Retries outside that transaction if the final
        # insert still races — see the rescue below.
        def write_chunk(survivors, attempt: 1)
          return BulkTransition::Result.new if survivors.empty?

          assign_sort_keys!(survivors)
          successful = []
          failed = []

          begin
            transition_class.transaction(requires_new: true) do
              writable, raced = flip_and_partition(survivors)
              failed.concat(raced)
              next if writable.empty?

              persist_writable!(writable)
              successful.concat(writable.map { |item| item[:object] })
            end
          rescue ::ActiveRecord::RecordNotUnique
            raise if attempt >= MAX_INSERT_ATTEMPTS

            # Rescued outside the transaction block, not around insert_all! within it:
            # on Postgres a failed statement leaves the transaction unusable until it's
            # rolled back, which only happens once the error escapes `transaction do
            # ... end`. Retrying the whole chunk (not a pre-filtered subset) is
            # deliberate: the retry's own flip + recheck re-discovers whoever just raced
            # and excludes them, with no need to parse the exception.
            retried = write_chunk(survivors, attempt: attempt + 1)
            successful.concat(retried.successful)
            failed.concat(retried.failed)
          end

          BulkTransition::Result.new(successful: successful, failed: failed)
        end

        # Flips most_recent for the has-history survivors' old rows, then re-reads every
        # survivor's parent to find out who raced — see #flip_most_recent for why this
        # needs no locking or RETURNING.
        def flip_and_partition(survivors)
          flip_ids = survivors.filter_map { |item| current_rows.dig(item[:object].id, :id) }
          flip_most_recent(flip_ids)

          parent_ids = survivors.map { |item| item[:object].id }
          raced_rows = most_recent_rows_for(parent_ids)

          writable, raced = survivors.partition { |item| !raced_rows.key?(item[:object].id) }
          failed = raced.map { |item| BulkTransition::Result::FailedItem.new(object: item[:object], reason: :conflict) }
          [writable, failed]
        end

        # Persists the survivors of #flip_and_partition: insert, batched cached-state
        # write, then per-item `after` (inside this still-open transaction — a raise
        # rolls it back) and a registered, deferred `after_commit` per item.
        def persist_writable!(writable)
          insert_survivors!(writable)
          maintain_cached_current_state_batch(writable, writable.first[:transition].to_state)

          writable.each do |item|
            after.call(item)
            transition_class.connection.add_transaction_record(
              ActiveRecordAfterCommitWrap.new(transition_class.connection) { after_commit.call(item) },
            )
          end
        end

        def assign_sort_keys!(survivors)
          survivors.each do |item|
            base_sort_key = current_rows.dig(item[:object].id, :sort_key)
            item[:transition].assign_attributes(
              sort_key: base_sort_key ? base_sort_key + 10 : 10,
              most_recent: true,
            )
          end
        end

        # Flips most_recent false for the given (snapshot-read) ids. No RETURNING or
        # locking needed: the UPDATE itself takes a row lock on every id it matches, so
        # a concurrent writer on the same parent blocks until our transaction ends.
        # Whether an id ends up false because we flipped it or a racer already had, it's
        # false either way afterward — so race detection can't come from re-querying
        # these ids; see #flip_and_partition's re-read instead.
        def flip_most_recent(ids)
          return if ids.empty?

          set_attrs = { most_recent: ActiveRecord.not_most_recent_value(transition_class, db_cast: false) }
          column, timestamp = ActiveRecord.updated_column_and_timestamp(transition_class)
          set_attrs[column] = timestamp if column

          transition_class.where(id: ids, most_recent: true).update_all(set_attrs)
        end

        # Excludes "id" (let the DB generate it) and timestamp columns (items built via
        # #build_transition carry these as explicit nil, which would otherwise suppress
        # insert_all!'s own record_timestamps: true and insert literal NULLs).
        #
        # Uses insert_all! (bang), not insert_all: plain insert_all silently does ON
        # CONFLICT DO NOTHING and never raises on a unique violation — it would drop a
        # conflicting row instead of failing it as :conflict, making #write_chunk's
        # RecordNotUnique retry dead code. insert_all! raises, matching #save!'s
        # behaviour on the single-object path.
        def insert_survivors!(writable)
          timestamp_columns = TIMESTAMP_COLUMNS & transition_class.column_names
          insert_attrs = writable.map { |item| item[:transition].attributes.except("id", *timestamp_columns) }

          if transition_class.connection.supports_insert_returning?
            result = transition_class.insert_all!(insert_attrs, returning: transition_class.column_names,
                                                                record_timestamps: true)
            rows_by_parent_id = index_rows_by_parent_id(result.to_a)
          else
            transition_class.insert_all!(insert_attrs, record_timestamps: true)
            rows_by_parent_id = reselect_rows_by_parent_id(writable)
          end

          hydrate!(writable, rows_by_parent_id)
        end

        def index_rows_by_parent_id(rows)
          rows.to_h { |row| [row[foreign_key], row] }
        end

        # MySQL has no insert_all! RETURNING support — re-read the rows we just
        # inserted instead. Safe here: has-history parents are lock-protected and
        # no-history parents were just verified then inserted, so nothing else can be
        # writing a competing transition for them right now.
        def reselect_rows_by_parent_id(writable)
          parent_ids = writable.map { |item| item[:object].id }

          transition_class.where(ActiveRecord.most_recent_transitions(transition_class, foreign_key, parent_ids)).
            to_h { |record| [record[foreign_key], record.attributes] }
        end

        # Merges the recovered row onto the already-`before`-mutated attributes (not the
        # recovered row alone, so a `before` callback's mutation survives), then rebuilds
        # a persisted record via .instantiate — materializes a row without re-running
        # validations/callbacks/save!.
        def hydrate!(writable, rows_by_parent_id)
          writable.each do |item|
            row = rows_by_parent_id.fetch(item[:object].id)
            merged = item[:transition].attributes.merge(row)
            item[:transition] = item[:transition].class.instantiate(merged)
          end
        end

        # Batched generalization of #maintain_cached_current_state: one UPDATE for every
        # written parent, since the target state is homogeneous across the whole chunk.
        def maintain_cached_current_state_batch(writable, to_state)
          return unless parent_model_class.respond_to?(:cached_state_column_name)

          column = parent_model_class.cached_state_column_name
          unless parent_model_class.column_names.include?(column.to_s)
            raise ArgumentError,
                  "cache_current_state_column: #{column.inspect} is not a column " \
                  "on #{parent_model_class.name}"
          end

          attributes = { column => to_state }
          attributes[:updated_at] = Time.current if parent_model_class.cached_current_state_touch_updated_at?
          parent_ids = writable.map { |item| item[:object].id }
          parent_model_class.where(id: parent_ids).update_all(attributes)
        end
      end
    end
  end
end
