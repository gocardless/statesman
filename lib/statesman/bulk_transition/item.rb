# frozen_string_literal: true

module Statesman
  class BulkTransition
    # Pairs a machine with metadata specific to it, merged over the shared `metadata:`
    # passed to BulkTransition.call (item wins on key conflicts) — visible to guards and
    # before/after callbacks alike, not just the written transition.
    Item = Struct.new(:machine, :metadata, keyword_init: true) do
      def initialize(machine:, metadata: {})
        super
      end
    end
  end
end
