# frozen_string_literal: true

require_relative "callback"
require_relative "exceptions"

module Statesman
  class Guard < Callback
    def call(object = nil, last_transition = nil, metadata = nil)
      raise GuardFailedError.new(from, to, callback, object) unless super
    end
  end
end
