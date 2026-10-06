# frozen_string_literal: true

require_relative "bulk_transition/result"

module Statesman
  # The sole entry point for transitioning many machines to the same state. .call takes
  # already-built machines only — no object-wrapping, callers construct their own
  # (`SomeMachine.new(object)`) before calling in. Mixed Machine subclasses in one call
  # are fine: machines are grouped by (class, current_state) and each group is validated
  # through its own class's rules (successors/guards are per-subclass DSL state that only
  # the including class has — see Machine.validate_bulk_transition). #persist is then the
  # write side for one such already-validated, already-homogeneous group: builds each
  # transition, runs `before`, persists via the adapter's own bulk_create, then
  # dispatches `after`/`after_commit` for whatever didn't fail — each item already
  # carries its own machine and transition, so there's no need to work backward from the
  # objects bulk_create hands back. The three skip_* options are independent since
  # `after` vs `after_commit` serve different purposes (see Machine.after_transition).
  #
  # Doesn't chunk `machines` itself unless `in_batches_of` is given — safe batch size
  # depends on the caller's own DB, which this gem can't know. The duplicate-object check
  # runs across *all* machines up front, before any batching, so a duplicate split across
  # two batches is still caught. With on_failure: :raise, a failure part-way through
  # aborts the remaining batches — already-persisted batches are not rolled back.
  class BulkTransition
    def self.call(machines, new_state, in_batches_of: nil, metadata: {}, on_failure: :collect,
                  skip_guards: false, skip_before_callbacks: false, skip_after_callbacks: false,
                  skip_after_commit_callbacks: false)
      new_state = new_state.to_s
      validate_no_duplicate_objects(machines)

      batches = in_batches_of ? machines.each_slice(validate_batch_size(in_batches_of)) : [machines]
      results = batches.map do |batch|
        transition_batch(batch, new_state, metadata: metadata, on_failure: on_failure,
                                           skip_guards: skip_guards,
                                           skip_before_callbacks: skip_before_callbacks,
                                           skip_after_callbacks: skip_after_callbacks,
                                           skip_after_commit_callbacks: skip_after_commit_callbacks)
      end

      Result.new(successful: results.flat_map(&:successful), failed: results.flat_map(&:failed))
    end

    class << self
      private

      # Keyed on (object, machine class), not object alone: one object can legitimately
      # run two different state machines (e.g. two independent transition histories on
      # the same record), which isn't a duplicate call for either machine.
      def validate_no_duplicate_objects(machines)
        duplicates = machines.map { |machine| [machine.object, machine.class] }.
          tally.select { |_, count| count > 1 }.keys
        return if duplicates.empty?

        raise ArgumentError, "BulkTransition does not support duplicate objects: " \
                             "#{duplicates.map(&:first).inspect}"
      end

      def validate_batch_size(in_batches_of)
        return in_batches_of if in_batches_of.is_a?(Integer) && in_batches_of.positive?

        raise ArgumentError, "in_batches_of must be a positive integer, got: #{in_batches_of.inspect}"
      end

      # One validate+persist cycle for a single batch of already duplicate-checked
      # machines — the body of .call prior to `in_batches_of` support, extracted so it
      # can run once per batch. Buckets by machine class too, not just current_state: a
      # machine may be a subclass with its own guards/successors — validating it against
      # the wrong class's rules would silently skip whatever that subclass adds.
      def transition_batch(machines, new_state, metadata:, on_failure:, skip_guards:, skip_before_callbacks:,
                           skip_after_callbacks:, skip_after_commit_callbacks:)
        writer = new(new_state, metadata: metadata, skip_before_callbacks: skip_before_callbacks,
                                skip_after_callbacks: skip_after_callbacks,
                                skip_after_commit_callbacks: skip_after_commit_callbacks)
        successful = []
        failed = []

        machines.group_by { |machine| [machine.class, machine.current_state] }.each do |(machine_class, from), bucket|
          survivors, failures = machine_class.validate_bulk_transition(bucket, from: from, to: new_state,
                                                                               metadata: metadata,
                                                                               skip_guards: skip_guards,
                                                                               on_failure: on_failure)
          failed.concat(bulk_failed_items(failures))
          next if survivors.empty?

          result = writer.persist(from, survivors)
          successful.concat(result.successful)
          failed.concat(result.failed)
        end

        Result.new(successful: successful, failed: failed)
      end

      def bulk_failed_items(failures)
        failures.map do |failure|
          Result::FailedItem.new(object: failure[:machine].object, reason: failure[:reason], error: failure[:error])
        end
      end
    end

    def initialize(new_state, metadata: {}, skip_before_callbacks: false, skip_after_callbacks: false,
                   skip_after_commit_callbacks: false)
      @new_state = new_state
      @metadata = metadata
      @skip_before_callbacks = skip_before_callbacks
      @skip_after_callbacks = skip_after_callbacks
      @skip_after_commit_callbacks = skip_after_commit_callbacks
    end

    def persist(from, machines)
      return Result.new if machines.empty?

      items = machines.map do |machine|
        transition = machine.storage_adapter.build_transition(from, @new_state, @metadata)
        machine.execute(:before, from, @new_state, transition) unless @skip_before_callbacks

        { object: machine.object, adapter: machine.storage_adapter, transition: transition, machine: machine }
      end

      adapter_class = uniform_adapter_class(items)
      result = adapter_class.bulk_create(items)

      dispatch_after_callbacks(from, items, result.failed)

      result
    end

    private

    # bulk_create is called once per bucket, so every item must share one adapter class —
    # otherwise some would silently hit a bulk_create that doesn't know how to persist
    # them. Can't happen via .call today, since machines are grouped by class (and
    # therefore adapter) before reaching #persist, but cheap to guard against a Machine
    # subclass that varies its adapter per object. Always raises, regardless of
    # on_failure: this is a Machine-subclass configuration bug, not a per-item outcome a
    # caller would want collected into Result#failed.
    def uniform_adapter_class(items)
      adapter_classes = items.map { |item| item[:adapter].class }.uniq
      return adapter_classes.first if adapter_classes.one?

      raise ArgumentError, "BulkTransition requires every object to use the same storage " \
                           "adapter, got: #{adapter_classes.join(', ')}"
    end

    def dispatch_after_callbacks(from, items, failures)
      return if @skip_after_callbacks && @skip_after_commit_callbacks

      failed_objects = failures.to_h { |failure| [failure.object, true] }

      items.each do |item|
        next if failed_objects.key?(item[:object])

        item[:machine].execute(:after, from, @new_state, item[:transition]) unless @skip_after_callbacks
        unless @skip_after_commit_callbacks
          item[:machine].execute(:after_commit, from, @new_state, item[:transition])
        end
      end
    end
  end
end
