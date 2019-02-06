require "json"
require_relative "exceptions"

module Statesman
  class Config
    attr_reader :adapter_class, :requires_new

    def initialize(block = nil)
      instance_eval(&block) unless block.nil?
    end

    def storage_adapter(adapter_class)
      @adapter_class = adapter_class
    end

    def requires_new_transaction(requires_new)
      @requires_new = requires_new
    end
  end
end
