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
    # check — every caller here is a real bulk attempt.
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

    def write_batch(items)
      return Result.new if items.empty?

      entries, build_failed = build_transitions(items)
      raise build_failed.first.error if @on_failure == :raise && build_failed.any?

      ready, before_failed = run_before_callbacks(entries)
      failed = build_failed + before_failed

      return Result.new(failed: failed) if ready.empty?

      result = @adapter_class.bulk_create(ready)
      after_failed = dispatch_after_callbacks(ready, result.failed)

      Result.new(successful: result.successful, failed: failed + result.failed + after_failed)
    end

    # Delegates the actual building of each item's transition to the adapter class
    # (see Adapters::Memory.build_transitions), rather than calling #build_transition on
    # each machine's own adapter instance one at a time here. That seam lets an adapter
    # batch away the per-object cost of building a transition (e.g. an ActiveRecord
    # adapter could preload every parent's `last` transition in a single query instead of
    # one query per item) without BulkTransition needing to know how.
    def build_transitions(items)
      payload = items.map do |item|
        machine = item.machine
        {
          object: machine.object, adapter: machine.storage_adapter,
          from: @from_state, to: @to_state, metadata: @metadata.merge(item.metadata)
        }
      end

      @adapter_class.build_transitions(payload)
    end

    def run_before_callbacks(entries)
      before_callbacks = @skip_before_callbacks ? [] : callbacks_for(:before)
      return [entries, []] if before_callbacks.empty?

      ready = []
      failed = []

      entries.each do |entry|
        before_callbacks.each { |callback| callback.call(entry[:object], entry[:transition]) }
        ready << entry
      rescue StandardError => e
        raise if @on_failure == :raise

        failed << Result::FailedItem.new(object: entry[:object], reason: :before_callback, error: e)
      end

      [ready, failed]
    end

    # An after/after_commit callback raising doesn't undo the write — the transition is
    # already durably persisted by this point — so a failure here is recorded as
    # reason: :after_callback in Result#failed *in addition to* the object staying in
    # Result#successful, rather than moving it across. Each entry's callbacks are rescued
    # individually so one entry's broken callback doesn't stop the rest of the batch from
    # getting theirs.
    def dispatch_after_callbacks(entries, failures)
      return [] if @skip_after_callbacks && @skip_after_commit_callbacks

      failed_objects = failures.to_h { |failure| [failure.object, true] }
      after_callbacks = @skip_after_callbacks ? [] : callbacks_for(:after)
      after_commit_callbacks = @skip_after_commit_callbacks ? [] : callbacks_for(:after_commit)

      entries.
        reject { |entry| failed_objects.key?(entry[:object]) }.
        filter_map { |entry| dispatch_after_callbacks_for(entry, after_callbacks, after_commit_callbacks) }
    end

    def dispatch_after_callbacks_for(entry, after_callbacks, after_commit_callbacks)
      after_callbacks.each { |callback| callback.call(entry[:object], entry[:transition]) }
      after_commit_callbacks.each { |callback| callback.call(entry[:object], entry[:transition]) }
      nil
    rescue StandardError => e
      raise if @on_failure == :raise

      Result::FailedItem.new(object: entry[:object], reason: :after_callback, error: e)
    end

    def callbacks_for(phase)
      @machine_class.callbacks[phase].select { |callback| callback.applies_to?(from: @from_state, to: @to_state) }
    end
  end
end
