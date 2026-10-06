# frozen_string_literal: true

require_relative "bulk_transition/result"

module Statesman
  # The sole entry point for transitioning many machines of one Machine class, all
  # starting from the same state, to the same new state. .call builds one instance,
  # capturing machine_class/from_state/to_state/metadata/on_failure/the skip_* flags
  # once, and delegates to #call — there's one of these per bulk operation, not a pile of
  # class methods passing the same handful of values to each other. There's no
  # transition_class option here: each machine already carries its own (it was fixed when
  # the caller built it via `machine_class.new(object, transition_class: ...)`), and
  # #write_batch reads the adapter straight off a machine's own `storage_adapter` rather
  # than re-deriving it from a transition_class this class would otherwise have to accept
  # and keep in sync. Machine itself stays entirely single-machine: nothing here needs
  # anything from it beyond what was already public (successors, callbacks, a machine's
  # own object/last_transition/storage_adapter/execute_on_failure) — successors/guards
  # are per-subclass DSL state that only the including class has anyway, so there's no
  # cross-class or cross-state validation this could usefully share, which is also why a
  # caller with machines spanning several Machine classes or several from-states builds
  # one instance per group instead.
  #
  # `machines` must each be an instance of exactly `machine_class` — #call checks this up
  # front and raises ArgumentError otherwise. Not `is_a?`: callbacks are dispatched off
  # `machine_class.callbacks` (see #callbacks_for), which are per-class, not inherited by
  # subclasses, so a machine that's actually an instance of some subclass would silently
  # run under the base class's guards/callbacks instead of its own.
  #
  # Whether `from_state -> to_state` is even a declared transition for machine_class is
  # checked once, up front, via the class's own Machine.validate_from_and_to_state — not
  # per machine and not per batch, since it depends on neither (same reasoning as
  # `from_state` itself: one instance, one pair). This isn't a per-object runtime outcome
  # — nothing has been attempted on any machine yet — it's a fact about machine_class's
  # own configuration (does it declare this pair at all), the same question
  # validate_from_and_to_state already answers for callback registration. So, like
  # #validate_machine_types below, it always raises (InvalidTransitionError, regardless
  # of on_failure) rather than reporting a Result#failed per object: there's nothing
  # per-object to report when every object would fail identically for a reason that has
  # nothing to do with any of them.
  #
  # `from_state` is required and trusted as-is — it is never read back off each machine
  # (e.g. via a `current_state` lookup), which would mean one query per object just to
  # discover what the caller usually already knows (it's typically how the objects were
  # queried for in the first place, e.g. `Payment.where(state: "pending")`). This is the
  # seam a storage adapter's bulk persist can use to filter out objects that have since
  # moved on from `from_state` (e.g. a `WHERE to_state = from_state` on the bulk write,
  # the way Postgres raw-SQL bulk transitions typically do it) instead of this class
  # checking each object's state upfront — #write_batch already threads `from_state` down
  # to `build_transition` and into `adapter_class.bulk_create`, so an adapter is free to
  # use it that way without any change here.
  #
  # #write_batch is then the write side for one such already-validated, already-homogeneous
  # group: builds each transition, runs `before`, persists via the adapter's own
  # bulk_create, then dispatches `after`/`after_commit` for whatever didn't fail — each
  # item already carries its own object/adapter/transition, so there's no need to work
  # backward from the objects bulk_create hands back. The three skip_* options are
  # independent since `after` vs `after_commit` serve different purposes (see
  # Machine.after_transition). If `before` raises, on_failure: :raise lets it propagate;
  # :collect records a :before_callback failure for that item and excludes it from the
  # write, the same on_failure contract #run_guards already applies to guard failures.
  #
  # Doesn't chunk `machines` itself unless `in_batches_of` is given — safe batch size
  # depends on the caller's own DB, which this gem can't know. With on_failure: :raise, a
  # failure part-way through aborts the remaining batches — already-persisted batches are
  # not rolled back.
  class BulkTransition
    def self.call(machine_class, machines, from_state:, to_state:, in_batches_of: nil, metadata: {},
                  on_failure: :collect, skip_guards: false, skip_before_callbacks: false,
                  skip_after_callbacks: false, skip_after_commit_callbacks: false)
      new(machine_class, from_state: from_state, to_state: to_state, metadata: metadata, on_failure: on_failure,
                         skip_guards: skip_guards, skip_before_callbacks: skip_before_callbacks,
                         skip_after_callbacks: skip_after_callbacks,
                         skip_after_commit_callbacks: skip_after_commit_callbacks).
        call(machines, in_batches_of: in_batches_of)
    end

    def initialize(machine_class, from_state:, to_state:, metadata: {}, on_failure: :collect, skip_guards: false,
                   skip_before_callbacks: false, skip_after_callbacks: false, skip_after_commit_callbacks: false)
      @machine_class = machine_class
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
      validate_machine_types(machines)
      @machine_class.validate_from_and_to_state(@from_state, @to_state)

      batches = in_batches_of ? machines.each_slice(in_batches_of) : [machines]
      results = batches.map { |batch| transition_batch(batch) }

      Result.new(successful: results.flat_map(&:successful), failed: results.flat_map(&:failed))
    end

    private

    # A caller usage error, not a per-object runtime outcome (see the class comment on
    # why exact class, not `is_a?`) — so, like the from/to check above, it always raises
    # rather than reporting a Result#failed per machine.
    def validate_machine_types(machines)
      machines.each do |machine|
        next if machine.instance_of?(@machine_class)

        raise ArgumentError, "BulkTransition expects instances of #{@machine_class}, " \
                             "got #{machine.class}"
      end
    end

    # One validate+write cycle for a single batch of machines — the body of #call prior
    # to `in_batches_of` support, extracted so it can run once per batch. #run_guards
    # partitions `machines` into survivors/failures; only the survivors reach #write_batch.
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

    # Runs every applicable guard for (from, to) against each machine, same as a single
    # real transition would — guards are pure functions of (object, last_transition,
    # metadata) (see Guard#call), so this needs nothing from Machine beyond its already-
    # public class-level callback list and each machine's own object/last_transition.
    # #transition_batch skips calling this at all when skip_guards is set; here, it's
    # skipped entirely when simply no guards are declared for this from/to — the common
    # case either way.
    # on_failure: :raise re-raises the first GuardFailedError immediately; :collect keeps
    # going and reports every failure. Always notifies after_guard_failure — unlike
    # Machine#can_transition_to?'s dry-run check, every caller here is a real bulk attempt.
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

    # The write side for one already-validated, already-homogeneous group: builds each
    # transition, runs `before`, persists via the adapter's own bulk_create, then
    # dispatches `after`/`after_commit` for whatever didn't fail. The adapter class is
    # read straight off the first machine's own `storage_adapter` — every machine in the
    # batch was built from the same machine_class with the same transition_class (that's
    # what "already-homogeneous" means here), so any one of them names the right adapter
    # class for the whole batch. Every callback phase here is dispatched straight off
    # machine_class's own callback list (see #callbacks_for) rather than through a Machine
    # instance's #execute, so `items` only ever has to carry what bulk_create and the
    # callbacks actually use: object/adapter/transition.
    def write_batch(machines)
      return Result.new if machines.empty?

      adapter_class = machines.first.storage_adapter.class
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

      result = adapter_class.bulk_create(items)

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
