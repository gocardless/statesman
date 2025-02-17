# frozen_string_literal: true

require_relative "version"
require_relative "exceptions"
require_relative "guard"
require_relative "callback"
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

      private

      def define_state_constant(state_name)
        constant_name = state_name.upcase

        if const_defined?(constant_name)
          raise StateConstantConflictError, "Name conflict: '#{self.class.name}::#{constant_name}' is already defined"
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

    def guards_for(options = { from: nil, to: nil })
      select_callbacks_for(self.class.callbacks[:guards], options)
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
      from = to_s_or_nil(options[:from])
      to   = to_s_or_nil(options[:to])

      successors = self.class.successors[from] || []
      raise TransitionFailedError.new(from, to) unless successors.include?(to)

      # Call all guards, they raise exceptions if they fail
      guards_for(from: from, to: to).each do |guard|
        guard.call(@object, last_transition, options[:metadata])
      end
    end

    def to_s_or_nil(input)
      input.nil? ? input : input.to_s
    end
  end
end
