# frozen_string_literal: true

module Statesman
  # Namespace for bulk, race-safe state transitions - see BulkTransition::V1 for the
  # current implementation.
  module BulkTransition
    autoload :V1, "statesman/bulk_transition/v1"
  end
end
