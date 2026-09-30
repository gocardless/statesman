# frozen_string_literal: true

require_relative "version"
require_relative "exceptions"
require_relative "guard"
require_relative "callback"
require_relative "bulk_transition"
require_relative "adapters/memory_transition"

module Statesman
  # The main module, that should be `extend`ed in to state machine classes.
  module Machine
    def self.included(base)
      base.extend(ClassMethods)
      base.send(:attr_reader, :object)
    end

    # Retry any transitions that fail due to a TransitionConflictError
    def self.retry_conflicts(max_retries = 1)
      retry_attempt = 0

      begin
        yield
      rescue TransitionConflictError
        retry_attempt += 1
        retry_attempt <= max_retries ? retry : raise
      end
    end

    module ClassMethods
      attr_reader :initial_state

      def states
        @states ||= []
      end

      def state(name, options = { initial: false })
        name = name.to_s
        if options[:initial]
          validate_initial_state(name)
          @initial_state = name
        end
        define_state_constant(name)

        states << name
      end

      def remove_state(state_name)
        state_name = state_name.to_s

        remove_transitions(from: state_name)
        remove_transitions(to: state_name)
        remove_callbacks(from: state_name)
        remove_callbacks(to: state_name)

        @states.delete(state_name.to_s)
      end

      def successors
        @successors ||= {}
      end

      def callbacks
        @callbacks ||= {
          before: [],
          after: [],
          after_transition_failure: [],
          after_guard_failure: [],
          after_commit: [],
          guards: [],
        }
      end

      def transition(from: nil, to: nil)
        from = to_s_or_nil(from)
        to = array_to_s_or_nil(to)

        raise InvalidStateError, "No to states provided." if to.empty?

        successors[from] ||= []

        ([from] + to).each { |state| validate_state(state) }

        successors[from] += to
      end

      def remove_transitions(from: nil, to: nil)
        raise ArgumentError, "Both from and to can't be nil!" if from.nil? && to.nil?
        return if successors.nil?

        if from.present?
          @successors[from.to_s].delete(to.to_s) if to.present?
          @successors.delete(from.to_s) if to.nil? || successors[from.to_s].empty?
        elsif to.present?
          @successors.
            transform_values! { |to_states| to_states - [to.to_s] }.
            filter! { |_from_state, to_states| to_states.any? }
        end
      end

      def before_transition(options = {}, &block)
        add_callback(callback_type: :before, callback_class: Callback,
                     from: options[:from], to: options[:to], &block)
      end

      def guard_transition(options = {}, &block)
        add_callback(callback_type: :guards, callback_class: Guard,
                     from: options[:from], to: options[:to], &block)
      end

      def after_transition(options = { after_commit: false }, &block)
        callback_type = options[:after_commit] ? :after_commit : :after

        add_callback(callback_type: callback_type, callback_class: Callback,
                     from: options[:from], to: options[:to], &block)
      end

      def after_transition_failure(options = {}, &block)
        add_callback(callback_type: :after_transition_failure, callback_class: Callback,
                     from: options[:from], to: options[:to], &block)
      end

      def after_guard_failure(options = {}, &block)
        add_callback(callback_type: :after_guard_failure, callback_class: Callback,
                     from: options[:from], to: options[:to], &block)
      end

      def validate_callback_condition(options = { from: nil, to: nil })
        from = to_s_or_nil(options[:from])
        to   = array_to_s_or_nil(options[:to])

        ([from] + to).compact.each { |state| validate_state(state) }
        return if from.nil? && to.empty?

        validate_not_from_terminal_state(from)
        to.each { |state| validate_not_to_initial_state(state) }

        return if from.nil? || to.empty?

        to.each { |state| validate_from_and_to_state(from, state) }
      end

      # Check that the 'from' state is not terminal
      def validate_not_from_terminal_state(from)
        unless from.nil? || successors.key?(from)
          raise InvalidTransitionError,
                "Cannot transition away from terminal state '#{from}'"
        end
      end

      # Check that the 'to' state is not initial
      def validate_not_to_initial_state(to)
        unless to.nil? || successors.values.flatten.include?(to)
          raise InvalidTransitionError,
                "Cannot transition to initial state '#{to}'"
        end
      end

      # Check that the transition is valid when 'from' and 'to' are given
      def validate_from_and_to_state(from, to)
        unless successors.fetch(from, []).include?(to)
          raise InvalidTransitionError,
                "Cannot transition from '#{from}' to '#{to}'"
        end
      end

      # Transition many objects to the same state in one call. Validates directly (see
      # .validate_bulk_transition), the same way #transition_to! calls #validate_transition
      # directly; only survivors are handed to Statesman::BulkTransition for the write
      # side (build transition, `before`, adapter's bulk_create, `after`/`after_commit`).
      #
      # Doesn't chunk `objects` itself unless `in_batches_of` is given — safe batch size
      # depends on the caller's own DB, which this gem can't know. Callers may still slice
      # their own objects and call this once per slice instead; `in_batches_of` is just a
      # convenience for the common case of "run this in groups of N", one
      # validate+persist cycle per batch rather than one for the whole collection. The
      # duplicate-object check still runs across *all* objects up front, before any
      # batching, so a duplicate split across two batches is still caught. With
      # on_failure: :raise, a failure part-way through aborts the remaining batches —
      # already-persisted batches are not rolled back.
      #
      # Each entry may be a plain object (wrapped via `new`) or an already-built machine
      # of this class, used as-is — not required to be machines outright, so the common
      # case (`bulk_transition_to!(orders, :approved)`) stays ceremony-free. Passing an
      # already-warm machine matters for adapters that memoize per-instance (e.g.
      # Adapters::ActiveRecord#last caches @last_transition): that cache would otherwise
      # be lost to a cold `new(object)`.
      def bulk_transition_to!(objects, new_state:, in_batches_of: nil, metadata: {}, on_failure: :collect,
                              skip_guards: false, skip_before_callbacks: false, skip_after_callbacks: false,
                              skip_after_commit_callbacks: false)
        new_state = new_state.to_s
        machines = objects.map { |object| object.is_a?(self) ? object : new(object) }
        validate_no_duplicate_objects(machines)

        batches = in_batches_of ? machines.each_slice(validate_batch_size(in_batches_of)) : [machines]
        results = batches.map do |batch|
          bulk_transition_batch!(batch, new_state, metadata: metadata, on_failure: on_failure,
                                                   skip_guards: skip_guards,
                                                   skip_before_callbacks: skip_before_callbacks,
                                                   skip_after_callbacks: skip_after_callbacks,
                                                   skip_after_commit_callbacks: skip_after_commit_callbacks)
        end

        BulkTransition::Result.new(successful: results.flat_map(&:successful), failed: results.flat_map(&:failed))
      end

      # Shared validation core behind #validate_transition (one machine) and
      # .bulk_transition_to! (many) — caller guarantees every machine in `machines` is
      # currently in `from`. Computes the edge check and guard list once per call rather
      # than once per machine, since both depend only on (from, to); only the guard calls
      # themselves are per-machine.
      #
      # on_failure: :raise re-raises the first failure immediately, matching single-
      # transition semantics; :collect gathers every failure and keeps going, returning
      # [survivors, failures] as plain {machine:, reason:, error:} hashes — not a
      # BulkTransition::Result, since Machine shouldn't need to know that shape.
      def validate_bulk_transition(machines, from:, to:, metadata: {}, skip_guards: false, on_failure: :raise)
        from = from.to_s
        to = to.to_s

        edge_error = validate_bulk_edge(from, to)
        if edge_error
          raise edge_error if on_failure == :raise

          failed = machines.map { |machine| { machine: machine, reason: :invalid_current_state, error: edge_error } }
          return [[], failed]
        end

        applicable_guards = skip_guards ? [] : applicable_guards_for(from, to)
        run_bulk_guards(machines, applicable_guards, metadata, on_failure)
      end

      # Public so #guards_for can call it directly instead of duplicating this filter —
      # it exposes nothing callbacks[:guards] (already public) didn't already.
      def applicable_guards_for(from, to)
        callbacks[:guards].select { |guard| guard.applies_to?(from: from, to: to) }
      end

      private

      def validate_no_duplicate_objects(machines)
        duplicate_objects = machines.map(&:object).tally.select { |_, count| count > 1 }.keys
        return if duplicate_objects.empty?

        raise ArgumentError, "bulk_transition_to! does not support duplicate objects: #{duplicate_objects.inspect}"
      end

      def validate_batch_size(in_batches_of)
        return in_batches_of if in_batches_of.is_a?(Integer) && in_batches_of.positive?

        raise ArgumentError, "in_batches_of must be a positive integer, got: #{in_batches_of.inspect}"
      end

      # One validate+persist cycle for a single batch of already-built, already
      # duplicate-checked machines — the body of .bulk_transition_to! prior to
      # `in_batches_of` support, extracted so it can run once per batch.
      #
      # TODO: Verify DB usage against different machine conditions once develop the AR adapter
      # Buckets by machine class too, not just current_state: a pre-built machine passed in
      # (see the is_a?(self) check in .bulk_transition_to!) may be a subclass of `self`, with
      # its own guards/successors — validating it against `self`'s rules instead of its own
      # would silently skip whatever that subclass adds.
      def bulk_transition_batch!(machines, new_state, metadata:, on_failure:, skip_guards:, skip_before_callbacks:,
                                 skip_after_callbacks:, skip_after_commit_callbacks:)
        writer = BulkTransition.new(new_state, metadata: metadata, skip_before_callbacks: skip_before_callbacks,
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

        BulkTransition::Result.new(successful: successful, failed: failed)
      end

      def bulk_failed_items(failures)
        failures.map do |failure|
          BulkTransition::Result::FailedItem.new(object: failure[:machine].object, reason: failure[:reason],
                                                 error: failure[:error])
        end
      end

      def validate_bulk_edge(from, to)
        return if (successors[from] || []).include?(to)

        TransitionFailedError.new(from, to)
      end

      def run_bulk_guards(machines, applicable_guards, metadata, on_failure)
        survivors = []
        failed = []

        machines.each do |machine|
          applicable_guards.each { |guard| guard.call(machine.object, machine.last_transition, metadata) }
          survivors << machine
        rescue GuardFailedError => e
          raise if on_failure == :raise

          failed << { machine: machine, reason: :guard, error: e }
        end

        [survivors, failed]
      end

      def define_state_constant(state_name)
        constant_name = state_name.upcase.gsub(/[^A-Z0-9]/, "_")

        if const_defined?(constant_name)
          return if const_get(constant_name) == state_name

          raise StateConstantConflictError, "Name conflict: '#{name}::#{constant_name}' is already " \
                                            "defined as '#{const_get(constant_name)}' attempting to redefine " \
                                            "as '#{state_name}'"
        else
          const_set(constant_name, state_name)
        end
      end

      def add_callback(callback_type: nil, callback_class: nil,
                       from: nil, to: nil, &block)
        validate_callback_type_and_class(callback_type, callback_class)

        from = to_s_or_nil(from)
        to   = array_to_s_or_nil(to)

        validate_callback_condition(from: from, to: to)

        callbacks[callback_type] <<
          callback_class.new(from: from, to: to, callback: block)
      end

      def remove_callbacks(from: nil, to: nil)
        raise ArgumentError, "Both from and to can't be nil!" if from.nil? && to.nil?
        return if callbacks.nil?

        @callbacks.transform_values! do |callbacks|
          filter_callbacks(callbacks, from: from, to: to)
        end
      end

      def filter_callbacks(callbacks, from: nil, to: nil)
        callbacks.filter_map do |callback|
          next if callback.from == from && to.nil?

          if callback.to.include?(to) && (from.nil? || callback.from == from)
            next if callback.to == [to]

            callback = Statesman::Callback.new({
              from: callback.from,
              to: callback.to - [to],
              callback: callback.callback,
            })
          end

          callback
        end
      end

      def validate_callback_type_and_class(callback_type, callback_class)
        raise ArgumentError, "missing keyword: callback_type" if callback_type.nil?
        raise ArgumentError, "missing keyword: callback_class" if callback_class.nil?
      end

      def validate_state(state)
        unless states.include?(state.to_s)
          raise InvalidStateError, "Invalid state '#{state}'"
        end
      end

      def validate_initial_state(state)
        unless initial_state.nil?
          raise InvalidStateError, "Cannot set initial state to '#{state}', " \
                                   "already defined as #{initial_state}."
        end
      end

      def to_s_or_nil(input)
        input.nil? ? input : input.to_s
      end

      def array_to_s_or_nil(input)
        Array(input).map { |item| to_s_or_nil(item) }
      end
    end

    attr_reader :storage_adapter

    def initialize(object,
                   options = {
                     transition_class: Statesman::Adapters::MemoryTransition,
                     initial_transition: false,
                   })
      @object = object
      @transition_class = options[:transition_class]
      @storage_adapter = adapter_class(@transition_class).new(
        @transition_class, object, self, options
      )

      if options[:initial_transition]
        if history.empty? && self.class.initial_state
          @storage_adapter.create(nil, self.class.initial_state)
        end
      end

      send(:after_initialize) if respond_to? :after_initialize
    end

    def current_state(force_reload: false)
      last_action = last_transition(force_reload: force_reload)
      last_action ? last_action.to_state : self.class.initial_state
    end

    def in_state?(*states)
      states.flatten.any? { |state| current_state == state.to_s }
    end

    def allowed_transitions(metadata = {})
      successors_for(current_state).select do |state|
        can_transition_to?(state, metadata)
      end
    end

    def last_transition(force_reload: false)
      @storage_adapter.last(force_reload: force_reload)
    end

    def last_transition_to(state)
      history.reverse.find { |transition| transition.to_state.to_sym == state.to_sym }
    end

    def can_transition_to?(new_state, metadata = {})
      validate_transition(from: current_state,
                          to: new_state,
                          metadata: metadata)
      true
    rescue TransitionFailedError, GuardFailedError
      false
    end

    def history
      @storage_adapter.history
    end

    def transition_to!(new_state, metadata = {})
      initial_state = current_state
      new_state = new_state.to_s

      validate_transition(from: initial_state,
                          to: new_state,
                          metadata: metadata)

      @storage_adapter.create(initial_state, new_state, metadata)

      true
    rescue TransitionFailedError => e
      execute_on_failure(:after_transition_failure, initial_state, new_state, e)
      raise
    rescue GuardFailedError => e
      execute_on_failure(:after_guard_failure, initial_state, new_state, e)
      raise
    end

    def execute_on_failure(phase, initial_state, new_state, exception)
      callbacks = callbacks_for(phase, from: initial_state, to: new_state)
      callbacks.each { |cb| cb.call(@object, exception) }
    end

    def execute(phase, initial_state, new_state, transition)
      callbacks = callbacks_for(phase, from: initial_state, to: new_state)
      callbacks.each { |cb| cb.call(@object, transition) }
    end

    def transition_to(new_state, metadata = {})
      transition_to!(new_state, metadata)
    rescue TransitionFailedError, GuardFailedError
      false
    end

    def reset
      @storage_adapter.reset
    end

    private

    def adapter_class(transition_class)
      if transition_class == Statesman::Adapters::MemoryTransition
        Adapters::Memory
      else
        Statesman.storage_adapter
      end
    end

    def successors_for(from)
      self.class.successors[from] || []
    end

    # Delegates to the class-level .applicable_guards_for rather than duplicating its
    # callbacks[:guards].select { ... } filter here.
    def guards_for(options = { from: nil, to: nil })
      self.class.applicable_guards_for(to_s_or_nil(options[:from]), to_s_or_nil(options[:to]))
    end

    def callbacks_for(phase, options = { from: nil, to: nil })
      select_callbacks_for(self.class.callbacks[phase], options)
    end

    def select_callbacks_for(callbacks, options = { from: nil, to: nil })
      from = to_s_or_nil(options[:from])
      to   = to_s_or_nil(options[:to])
      callbacks.select { |callback| callback.applies_to?(from: from, to: to) }
    end

    def validate_transition(options = { from: nil, to: nil, metadata: nil })
      self.class.validate_bulk_transition(
        [self], from: options[:from], to: options[:to], metadata: options[:metadata], on_failure: :raise
      )
    end

    def to_s_or_nil(input)
      input.nil? ? input : input.to_s
    end
  end
end
