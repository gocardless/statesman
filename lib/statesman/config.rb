require "json"
require "statesman/exceptions"

module Statesman
  class Config
    attr_reader :adapter_class

    def initialize(block = nil)
      instance_eval(&block) unless block.nil?
    end

    # rubocop:disable TrivialAccessors
    def storage_adapter(adapter_class)
      @adapter_class = adapter_class
    end
    # rubocop:enable TrivialAccessors

    def transition_class(*args)
      args.each { |klass| klass.serialize(:metadata, JSON) }
    end

  end
end
