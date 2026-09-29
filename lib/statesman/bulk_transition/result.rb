# frozen_string_literal: true

module Statesman
  class BulkTransition
    class Result < Struct.new(:transitioned, :failed, keyword_init: true)
      FailedItem = Struct.new(:object, :reason, :error, keyword_init: true) do
        REASONS = %i[guard conflict invalid_current_state].freeze

        def initialize(object:, reason:, error: nil)
          unless REASONS.include?(reason)
            raise ArgumentError, "invalid reason: #{reason.inspect} (must be one of #{REASONS.inspect})"
          end

          super
        end
      end

      def initialize(transitioned: [], failed: [])
        super
      end

      def success?
        failed.empty?
      end

      # :all    - every item transitioned, nothing failed
      # :partial - some items transitioned, some failed
      # :none   - nothing transitioned, everything failed
      def status
        return :all if failed.empty?
        return :none if transitioned.empty?

        :partial
      end
    end
  end
end
