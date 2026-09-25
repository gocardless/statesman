# frozen_string_literal: true

module Statesman
  class BulkTransition
    class Failure
      REASONS = %i[guard conflict invalid_current_state].freeze

      attr_reader :object, :reason, :error

      def initialize(object:, reason:, error: nil)
        unless REASONS.include?(reason)
          raise ArgumentError, "invalid reason: #{reason.inspect} (must be one of #{REASONS.inspect})"
        end

        @object = object
        @reason = reason
        @error = error
      end
    end
  end
end
