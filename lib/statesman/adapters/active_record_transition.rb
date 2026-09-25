# frozen_string_literal: true

require "json"

module Statesman
  module Adapters
    module ActiveRecordTransition
      DEFAULT_UPDATED_TIMESTAMP_COLUMN = :updated_at

      class MetadataSerializer
        def self.dump(metadata)
          JSON.generate(metadata)
        end

        def self.load(metadata)
          JSON.parse(metadata) unless metadata.nil? || metadata.empty?
        end
      end

      extend ActiveSupport::Concern

      included do
        if ::ActiveRecord.gem_version >= Gem::Version.new("7.1")
          serialize :metadata, coder: MetadataSerializer
        else
          serialize :metadata, MetadataSerializer
        end

        class_attribute :updated_timestamp_column
        self.updated_timestamp_column = DEFAULT_UPDATED_TIMESTAMP_COLUMN
      end

      def from_state
        if has_attribute?(:from_state)
          self[:from_state]
        end
      end
    end
  end
end
