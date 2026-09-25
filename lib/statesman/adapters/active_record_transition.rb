# frozen_string_literal: true

require "json"

module Statesman
  module Adapters
    module ActiveRecordTransition
      extend ActiveSupport::Concern

      include ActiveRecordTransitionAttributes

      included do
        serialize :metadata, coder: JSON
      end
    end
  end
end
