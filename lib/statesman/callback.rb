require_relative "exceptions"

module Statesman
  class Callback
    attr_reader :from
    attr_reader :to
    attr_reader :callback

    def initialize(options = { from: nil, to: nil, callback: nil })
      unless options[:callback].respond_to?(:call)
        raise InvalidCallbackError, "No callback passed"
      end

      @from = options[:from]
      @to = options[:to]
      @callback = options[:callback]
    end

    def call(*args)
      callback.call(*args)
    end

    def applies_to?(options = { from: nil, to: nil })
      from = options[:from]
      to = options[:to]
      # rubocop:disable RedundantSelf
      (self.from.nil? && self.to.nil?) ||
      (from.nil? && to == self.to) ||
      (self.from.nil? && to == self.to) ||
      (from == self.from && to.nil?) ||
      (from == self.from && self.to.nil?) ||
      (from == self.from && to == self.to)
      # rubocop:enable RedundantSelf
    end
  end
end
