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

      def transition(from: nil, to: nil)
        successors[from] ||= []
        to = Array(to)

        ([from] + to).each do |state|
          unless valid_state?(state)
            raise InvalidStateError, "Invalid state '#{state}'"
          end
        end

        successors[from] += to
      end

      private
      def valid_state?(state)
        states.include?(state)
      end
    end
  end
end
