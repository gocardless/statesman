require "json"

module Statesman
  module Adapters
    class Memory
      attr_reader :transition_class
      attr_reader :history
      attr_reader :parent_model

      # We only accept mode as a parameter to maintain a consistent interface
      # with other adapters which require it.
      def initialize(transition_class, model)
        @history = []
        @transition_class = transition_class
        @parent_model = model
      end

      def create(to, metadata = nil)
        metadata = metadata_to_json(metadata)
        new_transistion = transition_class.new(to, next_sort_key, metadata)
        @history << new_transistion
        new_transistion
      end

      def last
        @history.sort_by(&:sort_key).last
      end

      private

      def metadata_to_json(metadata)
        metadata.to_json unless metadata.nil?
      end

      def next_sort_key
        (last && last.sort_key + 10) || 0
      end
    end
  end
end
