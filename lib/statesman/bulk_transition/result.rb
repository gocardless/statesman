# frozen_string_literal: true

module Statesman
  class BulkTransition
    class Result
      attr_reader :transitioned, :failed

      def initialize(transitioned: [], failed: [])
        @transitioned = transitioned
        @failed = failed
      end

      def success?
        failed.empty?
      end
    end
  end
end
