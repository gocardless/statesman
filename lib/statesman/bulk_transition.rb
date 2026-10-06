# frozen_string_literal: true

require_relative "bulk_transition/result"

module Statesman
  # Transitions many machines of one Machine class from one state to another in bulk.
  # .call builds an instance and delegates to #call.
  #
  # machine_class and adapter_class aren't passed in — they're extracted from `machines`
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
  # Doesn't chunk `machines` unless `in_batches_of` is given. With on_failure: :raise, a
  # failure part-way through aborts remaining batches; already-persisted batches are not
  # rolled back.
  class BulkTransition
    def self.call(machines, from_state:, to_state:, in_batches_of: nil, metadata: {},
                  on_failure: :collect, skip_guards: false, skip_before_callbacks: false,
                  skip_after_callbacks: false, skip_after_commit_callbacks: false)
      new(from_state: from_state, to_state: to_state, metadata: metadata, on_failure: on_failure,
          skip_guards: skip_guards, skip_before_callbacks: skip_before_callbacks,
          skip_after_callbacks: skip_after_callbacks,
          skip_after_commit_callbacks: skip_after_commit_callbacks).
        call(machines, in_batches_of: in_batches_of)
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

    def call(machines, in_batches_of: nil)
      return Result.new if machines.empty?

      @machine_class = extract_machine_class(machines)
      @adapter_class = extract_adapter_class(machines)
      @machine_class.validate_from_and_to_state(@from_state, @to_state)

      batches = in_batches_of ? machines.each_slice(in_batches_of) : [machines]
      results = batches.map { |batch| transition_batch(batch) }

      Result.new(successful: results.flat_map(&:successful), failed: results.flat_map(&:failed))
    end

    private

    def extract_machine_class(machines)
      classes = machines.map(&:class).uniq
      return classes.first if classes.size == 1

      raise ArgumentError, "BulkTransition expects every machine to be the same class, " \
                           "got: #{classes.inspect}"
    end

    def extract_adapter_class(machines)
      classes = machines.map { |machine| machine.storage_adapter.class }.uniq
      return classes.first if classes.size == 1

      raise ArgumentError, "BulkTransition expects every machine to share the same " \
                           "adapter class, got: #{classes.inspect}"
    end

    def transition_batch(machines)
      if @skip_guards
        successful = machines
        failed = []
      else
        successful, failures = run_guards(machines)
        failed = bulk_failed_items(failures)
      end

      return Result.new(failed: failed) if successful.empty?

      result = write_batch(successful)
      Result.new(successful: result.successful, failed: failed + result.failed)
    end

    # Always notifies after_guard_failure, unlike Machine#can_transition_to?'s dry-run
    # check — every caller here is a real bulk attempt.
    def run_guards(machines)
      applicable_guards = callbacks_for(:guards)
      return [machines, []] if applicable_guards.empty?

      successful = []
      failed = []

      machines.each do |machine|
        applicable_guards.each { |guard| guard.call(machine.object, machine.last_transition, @metadata) }
        successful << machine
      rescue GuardFailedError => e
        machine.execute_on_failure(:after_guard_failure, @from_state, @to_state, e)
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

    def write_batch(machines)
      return Result.new if machines.empty?

      before_callbacks = @skip_before_callbacks ? [] : callbacks_for(:before)
      items = []
      failed = []

      machines.each do |machine|
        transition = machine.storage_adapter.build_transition(@from_state, @to_state, @metadata.dup)
        before_callbacks.each { |callback| callback.call(machine.object, transition) }

        items << { object: machine.object, adapter: machine.storage_adapter, transition: transition }
      rescue StandardError => e
        raise if @on_failure == :raise

        failed << Result::FailedItem.new(object: machine.object, reason: :before_callback, error: e)
      end

      return Result.new(failed: failed) if items.empty?

      result = @adapter_class.bulk_create(items)

      dispatch_after_callbacks(items, result.failed)

      Result.new(successful: result.successful, failed: failed + result.failed)
    end

    def dispatch_after_callbacks(items, failures)
      return if @skip_after_callbacks && @skip_after_commit_callbacks

      failed_objects = failures.to_h { |failure| [failure.object, true] }
      after_callbacks = @skip_after_callbacks ? [] : callbacks_for(:after)
      after_commit_callbacks = @skip_after_commit_callbacks ? [] : callbacks_for(:after_commit)

      items.each do |item|
        next if failed_objects.key?(item[:object])

        after_callbacks.each { |callback| callback.call(item[:object], item[:transition]) }
        after_commit_callbacks.each { |callback| callback.call(item[:object], item[:transition]) }
      end
    end

    def callbacks_for(phase)
      @machine_class.callbacks[phase].select { |callback| callback.applies_to?(from: @from_state, to: @to_state) }
    end
  end
end
