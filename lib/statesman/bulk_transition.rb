# frozen_string_literal: true

require_relative "bulk_transition/result"
require_relative "bulk_transition/failure"
require_relative "exceptions"

module Statesman
  # Orchestrates Machine.bulk_transition_to!. Mirrors single-object semantics in two
  # phases per (chunk, from-state) bucket: Phase A validates the transition is a legal
  # edge and runs guards, entirely in Ruby, before anything is built or written. Phase B
  # builds each surviving transition, runs `before`, then hands persistence off to the
  # adapter's own `bulk_create` — which persists and, at whatever point is safe for that
  # adapter, invokes the `after`/`after_commit` dispatch we hand it.
  #
  # Callback ownership is split rather than uniform across adapters because `after`/
  # `after_commit` need the actual persisted record (a real id, assigned at write
  # time), and only the adapter's bulk_create knows when persistence has completed and
  # holds that record — so those two have to be adapter-side, or fed the persisted rows
  # back from it. Successor validation, guards, and `before` need nothing from the
  # write itself, so they run once, uniformly, here in the orchestrator instead.
  class BulkTransition
    def initialize(machine_class, objects, new_state, metadata: {}, on_failure: :collect,
                   batch_size: 100, skip_guards: false, skip_callbacks: false)
      @machine_class = machine_class
      @objects = objects
      @new_state = new_state.to_s
      @metadata = metadata
      @on_failure = on_failure
      @batch_size = batch_size
      @skip_guards = skip_guards
      @skip_callbacks = skip_callbacks
    end

    def call
      transitioned = []
      failed = []

      @objects.each_slice(@batch_size) do |chunk|
        machines_by_object = chunk.to_h do |object|
          [object, @machine_class.new(object)]
        end

        machines_by_object.group_by { |(_, machine)| machine.current_state }.each do |from, pairs|
          bucket_result = process_bucket(from, pairs)
          transitioned.concat(bucket_result.transitioned)
          failed.concat(bucket_result.failed)
        end
      end

      Result.new(transitioned: transitioned, failed: failed)
    end

    private

    def process_bucket(from, machine_pairs)
      survivors, phase_a_failures = run_phase_a(from, machine_pairs)
      phase_b_result = run_phase_b(from, survivors)

      Result.new(
        transitioned: phase_b_result.transitioned,
        failed: phase_a_failures + phase_b_result.failed,
      )
    end

    # Successor validation and guards, always in that order, entirely upstream of any
    # write. Successor validation is never skippable; guards are, via skip_guards. An
    # adapter's bulk_create is never handed an item that failed either check.
    def run_phase_a(from, machine_pairs)
      survivors = []
      failed = []

      machine_pairs.each do |object, machine|
        unless successor?(from)
          error = TransitionFailedError.new(from, @new_state)
          raise error if @on_failure == :raise

          failed << Failure.new(object: object, reason: :invalid_current_state, error: error)
          next
        end

        begin
          run_guards(object, machine, from) unless @skip_guards
        rescue GuardFailedError => e
          raise if @on_failure == :raise

          failed << Failure.new(object: object, reason: :guard, error: e)
          next
        end

        survivors << [object, machine]
      end

      [survivors, failed]
    end

    def successor?(from)
      (@machine_class.successors[from] || []).include?(@new_state)
    end

    def run_guards(object, machine, from)
      guards_for(from).each { |guard| guard.call(object, machine.last_transition, @metadata) }
    end

    def guards_for(from)
      @machine_class.callbacks[:guards].select { |guard| guard.applies_to?(from: from, to: @new_state) }
    end

    # Builds each surviving transition and runs `before` (unless skip_callbacks), then
    # persists the bucket via the adapter's own bulk_create, passing it our `after`/
    # `after_commit` dispatch to invoke once it's safe to do so.
    def run_phase_b(from, machine_pairs)
      return Result.new if machine_pairs.empty?

      items = machine_pairs.map do |object, machine|
        transition = machine.storage_adapter.build_transition(from, @new_state, @metadata)
        machine.execute(:before, from, @new_state, transition) unless @skip_callbacks

        { object: object, adapter: machine.storage_adapter, transition: transition }
      end

      machines_by_object = machine_pairs.to_h
      adapter_class = items.first[:adapter].class

      adapter_class.bulk_create(
        items,
        after_persist: callback_dispatcher(:after, from, machines_by_object),
        after_commit: callback_dispatcher(:after_commit, from, machines_by_object),
      )
    end

    def callback_dispatcher(phase, from, machines_by_object)
      return nil if @skip_callbacks

      ->(object, transition) do
        machines_by_object.fetch(object).execute(phase, from, @new_state, transition)
      end
    end
  end
end
