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

    def call(*args)
      callback.call(*args)
    end

    def applies_to?(from: nil, to: nil)
      # rubocop:disable RedundantSelf
      (from.nil? && to == self.to) ||
      (self.from.nil? && to == self.to) ||
      (from == self.from && to.nil?) ||
      (from == self.from && self.to.nil?) ||
      (from == self.from && to == self.to)
      # rubocop:enable RedundantSelf
    end
  end
end
