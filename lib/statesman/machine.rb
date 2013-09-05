require "statesman/version"
require "statesman/exceptions"

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
        before_callbacks << [from, to, block]
      end

      def after_transition(from: nil, to: nil, &block)
        validate_callback_condition(from: from, to: to)
        after_callbacks << [from, to, block]
      end

      def guard_transition(from: nil, to: nil, &block)
        validate_callback_condition(from: from, to: to)
        guards << [from, to, block]
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

    def transition_to(new_state)
      unless self.class.successors[current_state].include?(new_state)
    private

    def validate_transition(from: nil, to: nil)
      unless self.class.successors[from].include?(to)
        raise InvalidTransitionError,
          "Cannot transition from '#{from}' to '#{to}'"
      end
    end
  end
end
