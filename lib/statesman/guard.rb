# frozen_string_literal: true

require_relative "callback"
require_relative "exceptions"

module Statesman
  class Guard < Callback
    def call(*args)
      raise GuardFailedError.new(from, to, callback) unless super
    end
  end
end
