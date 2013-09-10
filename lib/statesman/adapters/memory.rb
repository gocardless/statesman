module Statesman
  module Adapters
    class Memory
      attr_accessor :transition_class
      attr_accessor :history

      def initialize(transition_class)
        @history = []
        @transition_class = transition_class
      end

      def create(from, to)
        new_transistion = transition_class.new(from, to)
        history << new_transistion
        new_transistion
      end

      def last
        history.last
      end
    end
  end
end
