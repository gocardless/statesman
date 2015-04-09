require "json"
require "sequel"

module Statesman
  module Adapters
    module SequelTransition
      def self.included(base)
        base.send(:plugin, :serialization, :json, :metadata)
      end
    end
  end
end
