module Statesman
  module Adapters
    module MongoidTransition
      def self.included(base)
        base.send(:alias_method, :metadata, :statesman_metadata)
        base.send(:alias_method, :metadata=, :statesman_metadata=)
      end
    end
  end
end
