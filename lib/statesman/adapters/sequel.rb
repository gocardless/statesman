require_relative "../exceptions"

module Statesman
  module Adapters
    class Sequel
      attr_reader :transition_class, :parent_model, :observer

      def initialize(transition_class, parent_model, observer)
        @transition_class = transition_class
        @parent_model = parent_model
        @observer = observer
      end

      def transition_class
      end

      def parent_model
      end

      def state_attr
      end

      def create
      end

      def history
        []
      end

      def last
      end
    end
  end
end
