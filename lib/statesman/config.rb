require "json"
require_relative "exceptions"

module Statesman
  class Config
    attr_reader :adapter_class

    def initialize(block = nil)
      instance_eval(&block) unless block.nil?
    end

    def storage_adapter(adapter_class)
      @adapter_class = adapter_class
    end
  end
end
