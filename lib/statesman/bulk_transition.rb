# frozen_string_literal: true

require_relative "bulk_transition/result"
require_relative "bulk_transition/item"

module Statesman
  # Transitions many machines of one Machine class from one state to another in bulk.
  # .call builds an instance and delegates to #call. `items` is an array of
  # BulkTransition::Item, each pairing a machine with its own metadata (see Item).
  #
  # machine_class and adapter_class aren't passed in — they're extracted from `items`
  # itself (#extract_machine_class, #extract_adapter_class), raising ArgumentError if the
  # batch isn't homogeneous. Exact class match, not `is_a?`: callbacks are dispatched off
  # machine_class.callbacks, which subclasses don't inherit, so a subclass instance mixed
  # into a base-class batch would silently run under the wrong callbacks.
  #
  # `from_state` is trusted as given, never read back off each machine — this is the seam
  # a storage adapter can use to filter out objects that have since moved on from
  # `from_state` during its own bulk write, instead of this class checking upfront.
  #
  # on_failure: :raise propagates the first failure immediately; :collect gathers every
  # failure into Result#failed and keeps going. Configuration-level failures (an
  # undeclared from/to pair, mismatched machine/adapter classes) always raise regardless
  # of on_failure, since they're facts about the call, not a per-object outcome.
  #
  # Doesn't chunk `items` unless `in_batches_of` is given. With on_failure: :raise, a
  # failure part-way through aborts remaining batches; already-persisted batches are not
  # rolled back.
  #
  # Guards are the one phase this class runs itself (#run_guards) — everything else
  # (building each transition, before/after/after_commit dispatch, persisting) is
  # entirely the adapter's job, via #write_batch's single call to adapter_class
  # .bulk_create. That's not a layer this class is skipping: each item's own adapter
  # instance already holds a reference to its own Machine (passed in as `observer` at
  # construction — see Machine#initialize), the exact same reference the single-object
  # write path already calls back through (`@observer.execute(:after, ...)`, etc.), so
  # an adapter dispatches precisely the same callbacks, resolved precisely the same way,
  # with no second callback-lookup implementation duplicated here. What genuinely is
  # adapter-specific — whether `after_commit` needs deferring until a real transaction
  # commits, whether `after` needs its own isolated transaction per item to avoid one
  # item's failure undoing a shared batch write — is a decision only the adapter can
  # make correctly, so it belongs there (see Adapters::ActiveRecord::BulkCreate),
  # not here.
  class BulkTransition
    def self.call(items, from_state:, to_state:, in_batches_of: nil, metadata: {},
                  on_failure: :collect, skip_guards: false, skip_before_callbacks: false,
                  skip_after_callbacks: false, skip_after_commit_callbacks: false)
      new(from_state: from_state, to_state: to_state, metadata: metadata, on_failure: on_failure,
          skip_guards: skip_guards, skip_before_callbacks: skip_before_callbacks,
          skip_after_callbacks: skip_after_callbacks,
          skip_after_commit_callbacks: skip_after_commit_callbacks).
        call(items, in_batches_of: in_batches_of)
    end

    def initialize(from_state:, to_state:, metadata: {}, on_failure: :collect, skip_guards: false,
                   skip_before_callbacks: false, skip_after_callbacks: false, skip_after_commit_callbacks: false)
      @from_state = from_state.to_s
      @to_state = to_state.to_s
      @metadata = metadata
      @on_failure = on_failure
      @skip_guards = skip_guards
      @skip_before_callbacks = skip_before_callbacks
      @skip_after_callbacks = skip_after_callbacks
      @skip_after_commit_callbacks = skip_after_commit_callbacks
    end

    def call(items, in_batches_of: nil)
      return Result.new if items.empty?

      @machine_class = extract_machine_class(items)
      @adapter_class = extract_adapter_class(items)
      @machine_class.validate_from_and_to_state(@from_state, @to_state)
      validate_no_duplicate_objects(items)

      batches = in_batches_of ? items.each_slice(in_batches_of) : [items]
      results = batches.map { |batch| transition_batch(batch) }

      Result.new(successful: results.flat_map(&:successful), failed: results.flat_map(&:failed))
    end

    private

    def extract_machine_class(items)
      extract_uniform_class(items, "every machine to be the same class") { |item| item.machine.class }
    end

    def extract_adapter_class(items)
      extract_uniform_class(items, "every machine to share the same adapter class") do |item|
        item.machine.storage_adapter.class
      end
    end

    def extract_uniform_class(items, requirement, &block)
      classes = items.map(&block).uniq
      return classes.first if classes.size == 1

      raise ArgumentError, "BulkTransition expects #{requirement}, got: #{classes.inspect}"
    end

    # Checked across *all* items up front, before any batching (see #call), so a
    # duplicate object split across two in_batches_of chunks is still caught — two
    # items for the same object would otherwise reach the adapter as two rows with
    # identical sort_key/most_recent during its own build phase, which (at least on an
    # adapter with the uniqueness constraints Adapters::ActiveRecord relies on) either
    # raises a raw, unhelpful database error or, with no such constraint, silently
    # leaves inconsistent state. Always raises, regardless of on_failure: this is a
    # caller bug — a fact about the call, not a per-object outcome.
    def validate_no_duplicate_objects(items)
      duplicate_objects = items.map { |item| item.machine.object }.tally.select { |_, count| count > 1 }.keys
      return if duplicate_objects.empty?

      raise ArgumentError, "BulkTransition does not support duplicate objects: #{duplicate_objects.inspect}"
    end

    def transition_batch(items)
      if @skip_guards
        successful = items
        failed = []
      else
        successful, failures = run_guards(items)
        failed = bulk_failed_items(failures)
      end

      return Result.new(failed: failed) if successful.empty?

      result = write_batch(successful)
      Result.new(successful: result.successful, failed: failed + result.failed)
    end

    # Always notifies after_guard_failure, unlike Machine#can_transition_to?'s dry-run
    # check — every caller here is a real bulk attempt. Guards aren't a Machine#execute
    # phase (there's no single-object adapter equivalent to delegate to), so this is the
    # one piece of per-item dispatch logic that stays here rather than moving to the
    # adapter.
    #
    # machine.last_transition is a query per item for any adapter that doesn't already
    # have it cached (e.g. a freshly-built Adapters::ActiveRecord machine) — there's no
    # batching seam here the way build_transitions has one on the write side. If any
    # guard reads it and per-item queries here matter for your batch size, machines
    # should be preloaded with their last transition before calling BulkTransition.call
    # for maximum efficiency — there's no built-in seam for this yet, so today that
    # means batch-fetching every parent's last transition yourself and populating each
    # machine's adapter cache with it before this runs, rather than letting this method
    # discover it one query at a time.
    def run_guards(items)
      applicable_guards = callbacks_for(:guards)
      return [items, []] if applicable_guards.empty?

      successful = []
      failed = []

      items.each do |item|
        machine = item.machine
        metadata = @metadata.merge(item.metadata)
        applicable_guards.each { |guard| guard.call(machine.object, machine.last_transition, metadata) }
        successful << item
      rescue GuardFailedError => e
        begin
          machine.execute_on_failure(:after_guard_failure, @from_state, @to_state, e)
        rescue StandardError
          nil # a broken after_guard_failure hook must not stop guard evaluation for the rest of the batch
        end

        raise if @on_failure == :raise

        failed << { object: machine.object, reason: :guard, error: e }
      end

      [successful, failed]
    end

    def bulk_failed_items(failures)
      failures.map do |failure|
        Result::FailedItem.new(object: failure[:object], reason: failure[:reason], error: failure[:error])
      end
    end

    # `payload` is each item's object/adapter/metadata — per-item metadata already
    # merged over the shared `metadata:` passed to .call (item wins on key conflicts),
    # merged fresh per item so one item's before callback mutating its own metadata
    # can't affect another's. Everything past this point — building each transition,
    # before/after/after_commit dispatch, persisting — is the adapter's job; see the
    # class comment above for why.
    def write_batch(items)
      return Result.new if items.empty?

      payload = items.map do |item|
        machine = item.machine
        { object: machine.object, adapter: machine.storage_adapter, metadata: @metadata.merge(item.metadata) }
      end

      @adapter_class.bulk_create(payload, from: @from_state, to: @to_state, on_failure: @on_failure,
                                          skip_before_callbacks: @skip_before_callbacks,
                                          skip_after_callbacks: @skip_after_callbacks,
                                          skip_after_commit_callbacks: @skip_after_commit_callbacks)
    end

    def callbacks_for(phase)
      @machine_class.callbacks[phase].select { |callback| callback.applies_to?(from: @from_state, to: @to_state) }
    end
  end
end
