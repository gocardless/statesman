# frozen_string_literal: true

require_relative "bulk_transition/result"

module Statesman
  # The write side of Machine.bulk_transition_to!, for one already-validated bucket of
  # survivors (validation lives on Machine — see Machine.validate_bulk_transition).
  # Builds each transition, runs `before`, persists via the adapter's own bulk_create,
  # then dispatches `after`/`after_commit` for whatever didn't fail — each item already
  # carries its own machine and transition, so there's no need to work backward from the
  # objects bulk_create hands back. The three skip_* options are independent since
  # `after` vs `after_commit` serve different purposes (see Machine.after_transition).
  class BulkTransition
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
    # them. Can't happen via bulk_transition_to! today, but cheap to guard against a
    # Machine subclass that varies its adapter per object. Always raises, regardless of
    # on_failure: this is a Machine-subclass configuration bug, not a per-item outcome a
    # caller would want collected into Result#failed.
    def uniform_adapter_class(items)
      adapter_classes = items.map { |item| item[:adapter].class }.uniq
      return adapter_classes.first if adapter_classes.one?

      raise ArgumentError, "bulk_transition_to! requires every object to use the same storage " \
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
