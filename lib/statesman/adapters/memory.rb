require "json"

module Statesman
  module Adapters
    class Memory
      attr_reader :transition_class
      attr_reader :history
      attr_reader :parent_model

      # We only accept mode as a parameter to maintain a consistent interface
      # with other adapters which require it.
      def initialize(transition_class, parent_model)
        @history = []
        @transition_class = transition_class
        @parent_model = parent_model
      end

      def create(to, before_cbs, after_cbs, metadata = nil)
        metadata = metadata_to_json(metadata)
        transition = transition_class.new(to, next_sort_key, metadata)

        before_cbs.each { |cb| cb.call(@parent_model, transition) }
        @history << transition
        after_cbs.each { |cb| cb.call(@parent_model, transition) }

        transition
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
