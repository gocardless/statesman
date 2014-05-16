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
      @require_strict_callbacks = Statesman.require_strict_callbacks
    end

    def call(*args)
      callback.call(*args)
    end

    def applies_to?(options = { from: nil, to: nil })
      matches(options[:from], options[:to])
    end

    private

    def matches(from, to)
      if @require_strict_callbacks
        matches_both_states(from, to)
      else
        matches_all_transitions ||
        matches_to_state(from, to) ||
        matches_from_state(from, to) ||
        matches_both_states(from, to)
      end
    end

    def matches_all_transitions
      from.nil? && to.nil?
    end

    def matches_from_state(from, to)
      (from == self.from  && (to.nil? || self.to.nil?))
    end

    def matches_to_state(from, to)
      ((from.nil? || self.from.nil?) && to == self.to)
    end

    def matches_both_states(from, to)
      from == self.from && to == self.to
    end
  end
end
