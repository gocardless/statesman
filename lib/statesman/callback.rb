require "statesman/exceptions"

module Statesman
  class Callback
    attr_reader :from
    attr_reader :to
    attr_reader :callback

    def initialize(from: nil, to: nil, callback: nil)
      unless callback.respond_to?(:call)
        raise InvalidCallbackError, "No callback passed"
      end

      @from = from
      @to = to
      @callback = callback
    end

    def call
      callback.call
    end

  end
end
