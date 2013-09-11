require "statesman/callback"
require "statesman/exceptions"

module Statesman
  class Guard < Callback

    def call(*args)
      unless super(*args)
        raise GuardFailedError,
              "Guard on transition from: '#{from}' to '#{to}' returned false"
      end
    end

  end
end
