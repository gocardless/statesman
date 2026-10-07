# frozen_string_literal: true

module Statesman
  class BulkTransition
    class Result < Struct.new(:successful, :failed, keyword_init: true)
      FailedItem = Struct.new(:object, :reason, :error, keyword_init: true) do
        REASONS = %i[guard build_transition before_callback conflict after_callback].freeze

        def initialize(object:, reason:, error: nil)
          unless REASONS.include?(reason)
            raise ArgumentError, "invalid reason: #{reason.inspect} (must be one of #{REASONS.inspect})"
          end

          super
        end
      end

      def initialize(successful: [], failed: [])
        super
      end

      def success?
        failed.empty?
      end

      # :all    - every item succeeded, nothing failed
      # :partial - some items succeeded, some failed
      # :none   - nothing succeeded, everything failed
      def status
        return :all if failed.empty?
        return :none if successful.empty?

        :partial
      end
    end
  end
end
