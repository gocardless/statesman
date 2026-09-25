# frozen_string_literal: true

require "json"
require_relative "../exceptions"
require_relative "../bulk_transition"

module Statesman
  module Adapters
    class Memory
      # Maps the exceptions raised by a single #create call to the
      # BulkTransition::Failure reason they represent.
      FAILURE_REASONS = {
        GuardFailedError => :guard,
        TransitionFailedError => :invalid_current_state,
        TransitionConflictError => :conflict,
      }.freeze

      attr_reader :transition_class
      attr_reader :parent_model

      # We only accept mode as a parameter to maintain a consistent interface
      # with other adapters which require it.
      def initialize(transition_class, parent_model, observer, _opts = {})
        @history = []
        @transition_class = transition_class
        @parent_model = parent_model
        @observer = observer
      end

      # A single adapter instance is bound to one parent object (see #initialize), so
      # bulk writing across many parents can't be an instance method here — it has to
      # take each object's own already-instantiated adapter instead.
      #
      # items: an Enumerable of { object:, adapter:, from:, to:, metadata: }, where
      # `adapter` is that object's own Adapters::Memory instance.
      def self.bulk_create(items)
        transitioned = []
        failed = []

        items.each do |item|
          item[:adapter].create(item[:from], item[:to], item[:metadata] || {})
          transitioned << item[:object]
        rescue GuardFailedError, TransitionFailedError, TransitionConflictError => e
          reason = FAILURE_REASONS.fetch(e.class)
          failed << BulkTransition::Failure.new(object: item[:object], reason: reason, error: e)
        end

        BulkTransition::Result.new(transitioned: transitioned, failed: failed)
      end

      def create(from, to, metadata = {})
        from = from.to_s
        to = to.to_s
        transition = transition_class.new(from, to, next_sort_key, metadata)

        @observer.execute(:before, from, to, transition)
        @history << transition
        @observer.execute(:after, from, to, transition)
        @observer.execute(:after_commit, from, to, transition)
        transition
      end

      def last(*)
        @history.max_by(&:sort_key)
      end

      def history(*)
        @history
      end

      def reset
        @history = []
      end

      private

      def next_sort_key
        (last && (last.sort_key + 10)) || 10
      end
    end
  end
end
