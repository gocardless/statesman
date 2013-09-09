require "statesman/version"
require "statesman/exceptions"
require "statesman/guard"
require "statesman/callback"

module Statesman
  # The main module, that should be `extend`ed in to state machine classes.
  module Machine
    def self.included(base)
      base.extend(ClassMethods)
      base.send(:attr_accessor, :current_state)
    end

    module ClassMethods
      def states
        @states ||= []
      end

      def state(name, initial: false)
        states << name
      end

      def successors
        @successors ||= {}
      end

      def before_callbacks
        @before_callbacks ||= []
      end

      def after_callbacks
        @after_callbacks ||= []
      end

      def guards
        @guards ||= []
      end

      def transition(from: nil, to: nil)
        successors[from] ||= []
        to = Array(to)

        ([from] + to).each { |state| validate_state(state) }

        successors[from] += to
      end

      def before_transition(from: nil, to: nil, &block)
        validate_callback_condition(from: from, to: to)
        before_callbacks << Callback.new(from: from, to: to, callback: block)
      end

      def after_transition(from: nil, to: nil, &block)
        validate_callback_condition(from: from, to: to)
        after_callbacks << Callback.new(from: from, to: to, callback: block)
      end

      def guard_transition(from: nil, to: nil, &block)
        validate_callback_condition(from: from, to: to)
        guards << Guard.new(from: from, to: to, callback: block)
      end

      def validate_callback_condition(from: nil, to: nil)
        [from, to].compact.each { |state| validate_state(state) }
        return if from.nil? && to.nil?

        # Check that the 'from' state is not terminal
        unless from.nil? || successors.keys.include?(from)
          raise InvalidTransitionError,
                "Cannont transition away from terminal state '#{from}'"
        end

        # Check that the 'to' state is not initial
        unless to.nil? || successors.values.flatten.include?(to)
          raise InvalidTransitionError,
                "Cannont transition to initial state '#{from}'"
        end

        # Check that the transition is valid when 'from' and 'to' are given
        unless successors.fetch(from, []).include?(to)
          raise InvalidTransitionError,
                "Cannot transition from '#{from}' to '#{to}'"
        end
      end

      private

      def validate_state(state)
        unless states.include?(state)
          raise InvalidStateError, "Invalid state '#{state}'"
        end
      end
    end

    def transition_to!(new_state)
      validate_transition(from: current_state, to: new_state)

      guards_for(from: current_state, to: new_state).each(&:call)
      before_callbacks_for(from: current_state, to: new_state).each(&:call)

      self.current_state = new_state

      after_callbacks_for(from: current_state, to: new_state).each(&:call)
    end

    def transition_to(new_state)
      self.transition_to!(new_state)
      true
    rescue
      false
    end

    def guards_for(from: nil, to: nil)
      select_callbacks_for(self.class.guards, from: from, to: to)
    end

    def before_callbacks_for(from: nil, to: nil)
      select_callbacks_for(self.class.before_callbacks, from: from, to: to)
    end

    def after_callbacks_for(from: nil, to: nil)
      select_callbacks_for(self.class.after_callbacks, from: from, to: to)
    end

    private

    def select_callbacks_for(callbacks, from: nil, to: nil)
      callbacks.select do |callback|
        (from.nil? && to == callback.to) ||
        (from == callback.from && to.nil?) ||
        (from == callback.from && to == callback.to)
      end
    end

    def validate_transition(from: nil, to: nil)
      unless self.class.successors[from].include?(to)
        raise InvalidTransitionError,
              "Cannot transition from '#{from}' to '#{to}'"
      end
    end

  end
end
