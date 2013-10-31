require "json"

module Statesman
  module Adapters
    module ActiveRecordTransition
      def self.included(base)
        base.send(:serialize, :metadata, JSON)
      end
    end
  end
end
