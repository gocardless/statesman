require "json"
require_relative "exceptions"

module Statesman
  class Config
    attr_reader :adapter_class, :require_strict_callbacks

    def initialize(block = nil)
      instance_eval(&block) unless block.nil?
    end

    # rubocop:disable TrivialAccessors
    def storage_adapter(adapter_class)
      @adapter_class = adapter_class
    end
    # rubocop:enable TrivialAccessors

    def callback_level(level = nil)
      @require_strict_callbacks = (level == 'strict')
    end
  end
end
