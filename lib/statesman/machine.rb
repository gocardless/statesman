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
        states << name
      end

      def successors
        @successors ||= {}
      end

      def callbacks
        @callbacks ||= {
          before:       [],
          after:        [],
          after_commit: [],
          guards:       []
        }
      end

      def transition(options = { from: nil, to: nil })
        from = to_s_or_nil(options[:from])
        to = Array(options[:to]).map { |item| to_s_or_nil(item) }

        successors[from] ||= []

        ([from] + to).each { |state| validate_state(state) }

        successors[from] += to
      end

      def before_transition(options = { from: nil, to: nil }, &block)
        from = to_s_or_nil(options[:from])
        to   = to_s_or_nil(options[:to])

        validate_callback_condition(from: from, to: to)
        callbacks[:before] << Callback.new(from: from, to: to, callback: block)
      end

      def after_transition(options = { from: nil, to: nil,
                                       after_commit: false }, &block)
        from = to_s_or_nil(options[:from])
        to   = to_s_or_nil(options[:to])

        validate_callback_condition(from: from, to: to)
        phase = options[:after_commit] ? :after_commit : :after
        callbacks[phase] << Callback.new(from: from, to: to, callback: block)
      end

      def guard_transition(options = { from: nil, to: nil }, &block)
        from = to_s_or_nil(options[:from])
        to   = to_s_or_nil(options[:to])

        validate_callback_condition(from: from, to: to)
        callbacks[:guards] << Guard.new(from: from, to: to, callback: block)
      end

      def before_revert(options = { from: nil, to: nil }, &block)
        from = to_s_or_nil(options[:from])
        to   = to_s_or_nil(options[:to])

        validate_revert_callback_condition(from: from, to: to)
        callbacks[:before] << Callback.new(from: from, to: to, callback: block)
      end


      def validate_revert_callback_condition(options = { from: nil, to: nil })
        from = to_s_or_nil(options[:from])
        to   = to_s_or_nil(options[:to])

        [from, to].compact.each { |state| validate_state(state) }
        return if from.nil? && to.nil?
      end

      def validate_callback_condition(options = { from: nil, to: nil })
        from = to_s_or_nil(options[:from])
        to   = to_s_or_nil(options[:to])

        [from, to].compact.each { |state| validate_state(state) }
        return if from.nil? && to.nil?

        validate_not_from_terminal_state(from)
        validate_not_to_initial_state(to)

        return if from.nil? || to.nil?

        validate_from_and_to_state(from, to)
      end

      # Check that the 'from' state is not terminal
      def validate_not_from_terminal_state(from)
        unless from.nil? || successors.keys.include?(from)
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

      def validate_state(state)
        unless states.include?(state.to_s)
          raise InvalidStateError, "Invalid state '#{state}'"
        end
      end

      def validate_initial_state(state)
        unless initial_state.nil?
          raise InvalidStateError, "Cannot set initial state to '#{state}', " +
                                   "already defined as #{initial_state}."
        end
      end

      def to_s_or_nil(input)
        input.nil? ? input : input.to_s
      end

    end

    def initialize(object,
                      options = {
                        transition_class: Statesman::Adapters::MemoryTransition
                      })
      @object = object
      @transition_class = options[:transition_class]
      @storage_adapter = Statesman.storage_adapter.new(
                                            @transition_class, object, self)
      send(:after_initialize) if respond_to? :after_initialize
    end

    def current_state
      last_action = last_transition
      last_action ? last_action.to_state : self.class.initial_state
    end

    def allowed_transitions
      successors_for(current_state).select do |state|
        can_transition_to?(state)
      end
    end

    def last_transition
      @storage_adapter.last
    end

    def can_transition_to?(new_state, metadata = nil)
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

    def transition_to!(new_state, metadata = nil)
      initial_state = current_state
      new_state = new_state.to_s

      validate_transition(from: initial_state,
                          to: new_state,
                          metadata: metadata)

      @storage_adapter.create(initial_state, new_state, metadata)

      true
    end

    def revert_to!(new_state, metadata = nil)
      metadata = metadata || {}
      initial_state = current_state.to_s
      new_state = new_state.to_s
      validate_revert( {from: initial_state,
                          to: new_state,
                          metadata: metadata } )

      #always skip guard for reverts
      metadata[:skip_guard] = true
      @storage_adapter.create(initial_state, new_state, metadata)
      true
    end

    def execute(phase, initial_state, new_state, transition)
      callbacks = callbacks_for(phase, from: initial_state, to: new_state)
      callbacks.each { |cb| cb.call(@object, transition) }
    end

    def transition_to(new_state, metadata = nil)
      self.transition_to!(new_state, metadata)
    rescue
      false
    end

    private

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
      unless successors.include?(to)
        raise TransitionFailedError,
              "Cannot transition from '#{from}' to '#{to}'"
      end

      # Call all guards, they raise exceptions if they fail
      guards_for(from: from, to: to).each do |guard|
        guard.call(@object, last_transition, options[:metadata])
      end
    end

    # Check that the 'from' state is not the initial - reverting!
    def validate_revert(options)
      from = to_s_or_nil(options[:from])
      to   = to_s_or_nil(options[:to])

      flat = self.class.successors.flatten.flatten.uniq

      unless (from.nil? && can_revert_to(to, flat)) || (to.nil? && can_revert_from(from, flat)) || can_revert_from_to(from, to, flat)
        raise InvalidTransitionError,
              "Cannot revert transition to '#{to}'"
      end
    end

    def can_revert_to(to, flat)
      flat.include?(to) && flat.index(to) < flat.index(flat.max)
    end

    def can_revert_from(from, flat)
      flat.include?(from) && flat.index(from) > 0
    end

    def can_revert_from_to(from, to, flat)
      flat.index(to).to_i < flat.index(from).to_i
    end

    def is_reverse_order?(from, to)
      flat = self.class.successors.flatten.flatten
      flat.index(from) > flat.index(to)
    end

    def to_s_or_nil(input)
      input.nil? ? input : input.to_s
    end
  end
end
