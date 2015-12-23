require "json"

module Statesman
  module Adapters
    class Memory
      attr_reader :transition_class
      attr_reader :history
      attr_reader :parent_model

      # We only accept mode as a parameter to maintain a consistent interface
      # with other adapters which require it.
      def initialize(transition_class, parent_model, observer, _ = {})
        @history = []
        @transition_class = transition_class
        @parent_model = parent_model
        @observer = observer
      end

      def create(from, to, metadata = {})
        from = from.to_s
        to = to.to_s
        transition = transition_class.new(to, next_sort_key, metadata)

        @observer.execute(:before, from, to, transition)
        @history << transition
        @observer.execute(:after, from, to, transition)
        @observer.execute(:after_commit, from, to, transition)
        transition
      end

      def last(*)
        @history.sort_by(&:sort_key).last
      end

      private

      def next_sort_key
        (last && last.sort_key + 10) || 10
      end
    end
  end
end
