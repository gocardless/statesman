# Adapters::Memory
# All adpators must define four methods:
#   initialize: Accepts a transition class
#   create:     Accepts from and to and creates a new transition class
#   history:    Returns the full transitino history
#   last:       Returns the latest transition history
#
module Statesman
  module Adapters
    class Memory
      attr_reader :transition_class
      attr_reader :history

      def initialize(transition_class)
        @history = []
        @transition_class = transition_class
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
