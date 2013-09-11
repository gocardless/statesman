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

      def create(from, to, metadata = nil)
        metadata = metadata_to_json(metadata)
        new_transistion = transition_class.new(from, to, metadata)
        @history << new_transistion
        new_transistion
      end

      def last
        @history.sort_by(&:created_at).last
      end

      private

      def metadata_to_json(metadata)
        metadata.to_json unless metadata.nil?
      end
    end
  end
end
