module Statesman
  module Adapters
    class ActiveRecord
      attr_reader :transition_class
      attr_reader :parent_model

      def initialize(transition_class, parent_model)
        @transition_class = transition_class
        @parent_model = parent_model
      end

      def create(from, to)
        transitions_for_parent.create(from: from, to: to)
      end

      def history
        transitions_for_parent.order(:created_at)
      end

      def last
        transitions_for_parent.order(:created_at).last
      end

      private

      def transitions_for_parent
        @parent_model.send(@transition_class.table_name)
      end
    end
  end
end
