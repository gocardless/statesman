# frozen_string_literal: true

require_relative "callback"
require_relative "exceptions"

module Statesman
  class Guard < Callback
    def call(*args)
      ActiveSupport::Notifications.instrument "guard.statesman", {
        subject: args.first.class.name,
        subject_id: args.first.id,
        to_state: to,
        from_state: from,
        callback: callback.to_s,
        resource: self.class.name,
      } do
        raise GuardFailedError.new(from, to) unless super(*args)
      end
    end
  end
end
