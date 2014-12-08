module Statesman
  module Adapters
    class MemoryTransition
      attr_accessor :created_at
      attr_accessor :updated_at
      attr_accessor :to_state
      attr_accessor :sort_key
      attr_accessor :metadata

      def initialize(to, sort_key, metadata = {})
        @created_at = Time.now
        @updated_at = Time.now
        @to_state = to
        @sort_key = sort_key
        @metadata = metadata
      end
    end
  end
end
