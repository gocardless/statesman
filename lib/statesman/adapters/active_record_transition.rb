# frozen_string_literal: true

require "json"

module Statesman
  module Adapters
    module ActiveRecordTransition
      DEFAULT_UPDATED_TIMESTAMP_COLUMN = :updated_at

      extend ActiveSupport::Concern

      included do
        serialize :metadata, JSON

        class_attribute :updated_timestamp_column
        self.updated_timestamp_column = DEFAULT_UPDATED_TIMESTAMP_COLUMN
      end

      def from_state
        if has_attribute?(:from_state)
          self[:from_state]
        else
          nil
        end
      end
    end
  end
end
