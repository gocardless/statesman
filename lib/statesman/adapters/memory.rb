module Statesman
  module Adapters
    class Memory
      attr_reader :transition_class
      attr_reader :history
      attr_reader :parent_model
      attr_reader :state_attr

      def initialize(transition_class, parent_model = nil, state_attr = nil)
        @history = []
        @transition_class = transition_class
        @parent_model = parent_model
        @state_attr = state_attr
      end

      def create(to, metadata = nil)
        metadata = metadata_to_json(metadata)
        new_transistion = transition_class.new(to, metadata)
        @history << new_transistion
        set_model_state(to)
        new_transistion
      end

      def last
        @history.sort_by(&:created_at).last
      end

      private

      def set_model_state(to)
        if [parent_model, state_attr].none?(&:nil?)
          parent_model.send("#{state_attr}=", to)
        end
      end

      def metadata_to_json(metadata)
        metadata.to_json unless metadata.nil?
      end
    end
  end
end
