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
    end
  end
end
