require_relative "callback"
require_relative "exceptions"

module Statesman
  class Guard < Callback
    attr_reader :name

    def initialize(options = { from: nil, to: nil, callback: nil })
      @name = options[:name]
      super
    end

    def call(*args)
      unless super(*args)
        raise GuardFailedError.new("Guard on transition from: '#{from}' to " \
                                   "'#{to}' returned false", guard_name: name)
      end
    end
  end
end
