# frozen_string_literal: true

require_relative "../../bulk_transition"
require_relative "uniform_adapter"

module Statesman
  module Adapters
    class ActiveRecord
      # The real implementation behind Adapters::ActiveRecord.bulk_create — see that
      # method for the full contract. `items` is an Enumerable of { object:, adapter:,
      # metadata: }, all sharing one bucket's `from`/`to` state; building each
      # transition, before/after/after_commit dispatch, and persisting are all this
      # one call's job — see the class comment on BulkTransition for why that's all
      # here rather than split across several adapter methods an orchestrator calls in
      # sequence.
      #
      # One instance per call, run in four phases:
      #
      # 1. #build_transitions — one batched read of every parent's current most_recent
      #    row (sort_key, to_state), instead of one query per item the way
      #    #build_transition alone would need. That same read is the only place `from`
      #    staleness can be checked (a parent whose most recent to_state no longer
      #    matches `from` has already moved on since this call's items were decided on)
      #    — reported as reason: :conflict, before a transition is even built for it.
      #
      # 2. #run_before_callbacks — per item, via that item's own adapter#observer (the
      #    owning Machine — see Machine#initialize), outside any transaction: nothing's
      #    persisted yet, so there's nothing to protect by holding one open.
      #
      # 3. #write_chunk — one transaction for the whole surviving chunk: flip
      #    most_recent, insert (fast `insert_all!`, or a `save!` loop fallback — see
      #    #save_fallback? — when `transition_class` has real validations/callbacks the
      #    fast path would silently skip), cached-state, and `after_commit` registration
      #    (see Adapters::ActiveRecord#defer_until_committed) — deliberately decoupled
      #    from whether `after` succeeds (see #dispatch_after_callbacks below).
      #    Mechanics: flip most_recent false for the has-history survivors' old rows,
      #    then re-read every survivor's parent to find out who raced — an honest,
      #    unraced flip leaves no most_recent row for that parent until the insert that
      #    follows, so any parent the re-read still finds a row for has raced, and is
      #    excluded as :conflict. This needs no RETURNING or locking: the flip UPDATE
      #    itself takes a row lock, so a concurrent writer on the same parent blocks
      #    until we commit or roll back. insert_all! persists the rest; if it still
      #    hits a RecordNotUnique (the one remaining race window, between the re-read
      #    and the INSERT), retry the whole chunk outside this transaction.
      #
      # 4. #dispatch_after_callbacks — once the chunk's write has already committed,
      #    one isolated transaction per item (see
      #    Adapters::ActiveRecord#with_own_transaction), not the chunk's own: `after`
      #    can be arbitrary, cascading application code (creating audit events,
      #    cancelling related records) that may need to be atomic with *each other*,
      #    but N items share one write — running `after` inside that same transaction
      #    would mean one item's raise rolling back every other item's already-good
      #    insert, and there's no way to undo just one row out of a batch write.
      class BulkCreate
        include UniformAdapter

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

        # #requires_save_fallback? below only treats a _validate_callbacks/
        # _create_callbacks/_save_callbacks entry as "the user's own business logic" if
        # it's neither of these — both are framework scaffolding present on an otherwise
        # plain transition model, confirmed empirically against a vanilla Rails 8.1 model:
        #
        # - :cant_modify_encrypted_attributes_when_frozen is registered in
        #   _validate_callbacks on *every* AR model by default, unrelated to whether the
        #   model actually declares an encrypted attribute. This is why the check below
        #   can't be a bare `_validate_callbacks.any?`.
        # - Statesman's own convention (see spec/support/active_record.rb) is
        #   `belongs_to :parent_model` on the transition class with no explicit autosave
        #   option — Rails registers a `before_save :autosave_associated_records_for_*`
        #   callback for that regardless, landing in _save_callbacks. This one is
        #   trickier than the encrypted-attributes case: it isn't present on every AR
        #   model, only on ones with an association, and it's added only once the
        #   association is declared. An earlier design for this check snapshotted a
        #   "baseline" callback-chain length at the point ActiveRecordTransition is
        #   included into the transition class, then diffed against it later — but
        #   Statesman's own convention declares `belongs_to` *after* `include
        #   Statesman::Adapters::ActiveRecordTransition`, so that baseline would always
        #   be captured too early and this callback would always show up as a "real"
        #   addition, permanently defeating the fast path for every user. Matching on
        #   the filter name instead sidesteps the ordering problem entirely: it's
        #   evaluated lazily, once the whole class body (including `belongs_to`) has run.
        # - A non-`optional:` `belongs_to` under `belongs_to_required_by_default` (the
        #   Rails 5+ app default, off by default for a bare ActiveRecord::Base outside a
        #   full Rails app, which is why this doesn't show up against this gem's own spec
        #   models) registers `validates_presence_of reflection.name, message: :required`
        #   — see ActiveRecord::Associations::Builder::BelongsTo. That's framework
        #   scaffolding too, not a real validation the caller wrote, so it needs its own
        #   check below: unlike the two filters above, it isn't a Symbol at all (a
        #   `validates ...`-style declaration registers the validator *instance* as the
        #   filter), so the bare `filter.is_a?(Symbol)` check never even looks at it.
        FRAMEWORK_CALLBACK_FILTERS = [:cant_modify_encrypted_attributes_when_frozen].freeze
        AUTOSAVE_CALLBACK_FILTER_PATTERN = /\Aautosave_associated_records_for_/
        REQUIRED_ASSOCIATION_PRESENCE_MESSAGE = :required

        def self.call(items, from:, to:, on_failure:, skip_before_callbacks:, skip_after_callbacks:,
                      skip_after_commit_callbacks:, model_validations: :auto)
          new(items, from: from, to: to, on_failure: on_failure, skip_before_callbacks: skip_before_callbacks,
                     skip_after_callbacks: skip_after_callbacks,
                     skip_after_commit_callbacks: skip_after_commit_callbacks,
                     model_validations: model_validations).call
        end

        def initialize(items, from:, to:, on_failure:, skip_before_callbacks:, skip_after_callbacks:,
                       skip_after_commit_callbacks:, model_validations: :auto)
          @items = items
          @from = from.to_s
          @to = to.to_s
          @on_failure = on_failure
          @skip_before_callbacks = skip_before_callbacks
          @skip_after_callbacks = skip_after_callbacks
          @skip_after_commit_callbacks = skip_after_commit_callbacks
          @model_validations = model_validations
        end

        def call
          return BulkTransition::Result.new if items.empty?

          assert_uniform_adapter!
          @save_fallback = resolve_save_fallback?

          entries, build_failed = build_transitions
          raise build_failed.first.error if on_failure == :raise && build_failed.any?

          ready, before_failed = run_before_callbacks(entries)
          failed = build_failed + before_failed
          return BulkTransition::Result.new(failed: failed) if ready.empty?

          result = write_chunk(ready)
          raise result.failed.first.error if on_failure == :raise && result.failed.any?

          after_failed = dispatch_after_callbacks(ready, result)

          BulkTransition::Result.new(successful: result.successful, failed: failed + result.failed + after_failed)
        end

        private

        attr_reader :items, :from, :to, :on_failure, :skip_before_callbacks, :skip_after_callbacks,
                    :skip_after_commit_callbacks, :model_validations

        # :skip/:enforce are explicit caller overrides of the fast-path/slow-path choice
        # (see BulkTransition for the option's full contract); :auto runs the real
        # detection below. Only called once #assert_uniform_adapter! has resolved
        # `transition_class` for the whole chunk, which is also what makes it safe to
        # decide this once here rather than per item.
        def resolve_save_fallback?
          case model_validations
          when :skip then false
          when :enforce then true
          else requires_save_fallback?
          end
        end

        # True if `transition_class` has any validation or create/save callback beyond
        # the two known framework ones excluded below — see the constants' comment for
        # why a bare `_validate_callbacks.any?`/baseline-diff approach doesn't work.
        # `.validators` (rather than raw _validate_callbacks) would miss a bare `validate
        # :my_method` callback, so every chain relevant to a #save! is scanned uniformly
        # here instead of treating validations and callbacks differently.
        def requires_save_fallback?
          chains = transition_class._validate_callbacks.to_a +
            transition_class._create_callbacks.to_a +
            transition_class._save_callbacks.to_a

          chains.any? { |callback| !framework_callback?(callback.filter) }
        end

        def framework_callback?(filter)
          if filter.is_a?(Symbol)
            FRAMEWORK_CALLBACK_FILTERS.include?(filter) || filter.match?(AUTOSAVE_CALLBACK_FILTER_PATTERN)
          else
            required_association_presence_validator?(filter)
          end
        end

        def required_association_presence_validator?(filter)
          filter.is_a?(::ActiveRecord::Validations::PresenceValidator) &&
            filter.options[:message] == REQUIRED_ASSOCIATION_PRESENCE_MESSAGE
        end

        def save_fallback?
          @save_fallback
        end

        # ---- 1. BUILD ----

        def build_transitions
          parent_ids = items.map { |item| item[:object].id }
          current_rows = most_recent_rows_for(parent_ids)

          entries = []
          failed = []
          items.each { |item| build_one(item, current_rows, entries, failed) }
          [entries, failed]
        end

        def build_one(item, current_rows, entries, failed)
          row = current_rows[item[:object].id]

          if row && row[:to_state] != from
            failed << conflict_failure(item, row)
          else
            transition = item[:adapter].build_transition(from, to, item[:metadata])
            transition.assign_attributes(sort_key: row ? row[:sort_key] + 10 : 10, most_recent: true)
            entries << { object: item[:object], adapter: item[:adapter], transition: transition,
                         most_recent_id: row && row[:id] }
          end
        rescue StandardError => e
          failed << BulkTransition::Result::FailedItem.new(object: item[:object], reason: :build_transition, error: e)
        end

        def conflict_failure(item, row)
          error = Statesman::TransitionConflictError.new(
            "#{item[:object].class} #{item[:object].id.inspect} is no longer in state " \
            "#{from.inspect} (now #{row[:to_state].inspect})",
          )
          BulkTransition::Result::FailedItem.new(object: item[:object], reason: :conflict, error: error)
        end

        # ---- 2. BEFORE ----

        def run_before_callbacks(entries)
          return [entries, []] if skip_before_callbacks

          ready = []
          failed = []
          entries.each do |entry|
            entry[:adapter].observer.execute(:before, from, to, entry[:transition])
            ready << entry
          rescue StandardError => e
            raise if on_failure == :raise

            failed << BulkTransition::Result::FailedItem.new(object: entry[:object], reason: :before_callback,
                                                             error: e)
          end
          [ready, failed]
        end

        # ---- 3. PERSIST (+ after_commit registration) ----

        def write_chunk(survivors, attempt: 1)
          return BulkTransition::Result.new if survivors.empty?

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
            # deliberate: the retry's own flip + recheck re-discovers whoever just
            # raced and excludes them, with no need to parse the exception.
            retried = write_chunk(survivors, attempt: attempt + 1)
            successful.concat(retried.successful)
            failed.concat(retried.failed)
          end

          BulkTransition::Result.new(successful: successful, failed: failed)
        end

        # `item[:most_recent_id]` is nil for a parent that had no history as of
        # #build_transitions's own read — filtered out of the flip target list (no old
        # row to flip) but still included in the re-read, so a brand-new racer that
        # inserted *first* history for that parent is still caught. Reused as-is even
        # on a retry (see #write_chunk): a flip targeting an id that's no longer
        # most_recent is just a no-op, and the re-read is what's authoritative either
        # way, so a stale id here is harmless.
        def flip_and_partition(survivors)
          flip_ids = survivors.filter_map { |item| item[:most_recent_id] }
          flip_most_recent(flip_ids)

          parent_ids = survivors.map { |item| item[:object].id }
          raced_rows = most_recent_rows_for(parent_ids)

          writable, raced = survivors.partition { |item| !raced_rows.key?(item[:object].id) }
          failed = raced.map { |item| conflict_failure(item, raced_rows[item[:object].id]) }
          [writable, failed]
        end

        # Persists the survivors of #flip_and_partition — via the fast insert_all! path,
        # or, if #save_fallback? says transition_class has real validations/callbacks
        # the fast path would silently skip, a save_survivors! loop instead — then
        # batched cached-state write, then — still inside this chunk's open transaction
        # — after_commit registration for every survivor, unconditionally (see
        # Adapters::ActiveRecord#defer_until_committed's own docs for why this doesn't
        # wait on #dispatch_after_callbacks).
        def persist_writable!(writable)
          save_fallback? ? save_survivors!(writable) : insert_survivors!(writable)
          maintain_cached_current_state_batch(writable, writable.first[:transition].to_state)
          register_after_commit(writable) unless skip_after_commit_callbacks
        end

        def register_after_commit(writable)
          writable.each do |item|
            item[:adapter].defer_until_committed do
              item[:adapter].observer.execute(:after_commit, from, to, item[:transition])
            end
          end
        end

        # Flips most_recent false for the given (snapshot-read) ids. No RETURNING or
        # locking needed: the UPDATE itself takes a row lock on every id it matches, so
        # a concurrent writer on the same parent blocks until our transaction ends.
        # Whether an id ends up false because we flipped it or a racer already had,
        # it's false either way afterward — so race detection can't come from
        # re-querying these ids; see #flip_and_partition's re-read instead.
        #
        # TODO: unlike the single-object write path (see #create_transition's
        # mysql_gaplock_protection? branch), this flip-then-insert ordering doesn't
        # account for MySQL's next-key locking on the partial unique index over
        # (most_recent, parent foreign key) — a concurrent bulk write for a different
        # parent could still hit the same gap-lock deadlock hazard that branch exists
        # to avoid. Bulk writes here have only been verified against PostgreSQL so far;
        # revisit before treating MySQL as a fully supported target for bulk_create.
        def flip_most_recent(ids)
          return if ids.empty?

          set_attrs = { most_recent: ActiveRecord.not_most_recent_value(transition_class, db_cast: false) }
          column, timestamp = ActiveRecord.updated_column_and_timestamp(transition_class)
          set_attrs[column] = timestamp if column

          transition_class.where(id: ids, most_recent: true).update_all(set_attrs)
        end

        # The save_fallback? counterpart to #insert_survivors!: one #save! per item,
        # inside the same still-open transaction, so transition_class's own validations/
        # before_create/before_save/etc. actually run. Deliberately skips the RETURNING/
        # reselect/#hydrate! dance entirely — a save!'d record is already the real
        # persisted row, no recovery step needed. Any ActiveRecord::RecordInvalid (a
        # real validation failure) or ActiveRecord::RecordNotSaved (a halted callback)
        # propagates out of here uncaught, aborting/rolling back the whole chunk — the
        # same semantics a raising `after` callback already has; this is not a per-item
        # :conflict/:guard-style failure and adds no new Result::FailedItem reason. A
        # RecordNotUnique still reaches #write_chunk's own rescue/retry unchanged, since
        # this runs inside the same transaction block that rescue wraps.
        def save_survivors!(writable)
          writable.each { |item| item[:transition].save! }
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

        # Merges the recovered row onto the already-`before`-mutated attributes (not
        # the recovered row alone, so a `before` callback's mutation survives), then
        # rebuilds a persisted record via .instantiate — materializes a row without
        # re-running validations/callbacks/save!. Not used by #save_survivors!, whose
        # save!'d record is already the real persisted row.
        def hydrate!(writable, rows_by_parent_id)
          writable.each do |item|
            row = rows_by_parent_id.fetch(item[:object].id)
            merged = item[:transition].attributes.merge(row)
            item[:transition] = item[:transition].class.instantiate(merged)
          end
        end

        # Batched generalization of a per-object cached-state write: one UPDATE for
        # every written parent, since the target state is homogeneous across the
        # whole chunk.
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

        # ---- 4. AFTER ----

        # Only dispatches to items the chunk write actually reported successful, so a
        # raced/conflicted item never gets `after` called for it. Skips opening any
        # transaction at all, for any item, when there's nothing to run — a machine
        # with no `after` callbacks (or skip_after_callbacks: true) shouldn't pay for N
        # empty transactions.
        def dispatch_after_callbacks(ready, result)
          return [] if skip_after_callbacks

          successful_objects = result.successful.to_h { |object| [object, true] }
          ready.
            select { |entry| successful_objects.key?(entry[:object]) }.
            filter_map { |entry| dispatch_after_callbacks_for(entry) }
        end

        # An `after` callback raising rolls back only this item's own isolated
        # transaction (see Adapters::ActiveRecord#with_own_transaction) — the
        # already-committed transition write is untouched regardless, so the object
        # still ends up in Result#successful; this is recorded as an *additional*
        # reason: :after_callback failure, not a replacement for it. on_failure: :raise
        # still re-raises (after that one transaction has already rolled back) rather
        # than collecting the failure, and — same as every other phase — stops
        # dispatching `after` to any later item in this chunk.
        def dispatch_after_callbacks_for(entry)
          entry[:adapter].with_own_transaction do
            entry[:adapter].observer.execute(:after, from, to, entry[:transition])
          end
          nil
        rescue StandardError => e
          raise if on_failure == :raise

          BulkTransition::Result::FailedItem.new(object: entry[:object], reason: :after_callback, error: e)
        end
      end
    end
  end
end
