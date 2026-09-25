# frozen_string_literal: true

module Statesman
  module Adapters
    # The interface the ActiveRecord adapter expects of a transition class. Included by
    # ActiveRecordTransition; include it directly when the metadata column is json or
    # jsonb, since those columns must not also be serialized.
    module ActiveRecordTransitionAttributes
      DEFAULT_UPDATED_TIMESTAMP_COLUMN = :updated_at

      extend ActiveSupport::Concern

      included do
        class_attribute :updated_timestamp_column,
                        default: DEFAULT_UPDATED_TIMESTAMP_COLUMN
      end

      def from_state
        if has_attribute?(:from_state)
          self[:from_state]
        end
      end
    end
  end
end
