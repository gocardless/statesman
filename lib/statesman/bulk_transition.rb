# frozen_string_literal: true

require_relative "bulk_transition/result"

module Statesman
  # The write side of Machine.bulk_transition_to!, for one from-state bucket of already-
  # validated survivors — see Machine.bulk_transition_to! for the validation that happens
  # upstream of this, and Machine.validate_bulk_transition for why that lives on Machine
  # rather than here. Builds each transition and runs `before` (unless
  # skip_before_callbacks), then persists the bucket via the adapter's own bulk_create,
  # which only persists. Once that reports back which items failed, dispatches `after`
  # (unless skip_after_callbacks) and `after_commit` (unless skip_after_commit_callbacks)
  # for every other item — each item already carries its own machine and transition
  # forward, so there's no need to work backward from the objects bulk_create hands back
  # to find them. The three skips are independent since each phase has its own use case
  # for being suppressed on its own — see Machine.after_transition's `:after` vs
  # `:after_commit` distinction.
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

    # adapter_class.bulk_create(items) is called once for the whole bucket, so every
    # item in it must actually be backed by the same adapter — otherwise we'd silently
    # hand some items to a bulk_create implementation that doesn't know how to persist
    # them (e.g. built for a different transition table). This can't happen via
    # Machine.bulk_transition_to! today, since it builds every machine the same way, but
    # it's cheap to guard against a Machine subclass that varies its adapter per object.
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
