module Statesman
  module Adapters
    class Memory
      attr_reader :transition_class
      attr_reader :history
      attr_reader :parent_model

      def initialize(transition_class, parent_model = nil)
        @history = []
        @transition_class = transition_class
        @parent_model = parent_model
      end

      def create(from, to)
        new_transistion = transition_class.new(from, to)
        @history << new_transistion
        new_transistion
      end

      def last
        @history.sort_by(&:created_at).last
      end
    end
  end
end
