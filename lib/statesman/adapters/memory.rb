# frozen_string_literal: true

require "json"
require_relative "../bulk_transition"

module Statesman
  module Adapters
    class Memory
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
      # take each object's own already-built transition and adapter instead.
      #
      # items: an Enumerable of { object:, adapter:, transition: }, where `adapter` is
      # that object's own Adapters::Memory instance and `transition` was already built
      # via #build_transition (and had `before` run on it, by the caller). Guard/
      # successor failures never reach here — that validation always happens upstream,
      # in Statesman::BulkTransition, before an item is built at all.
      #
      # Callback dispatch (before/after/after_commit) is deliberately left out at
      # this stage — this method only persists. Statesman::BulkTransition is the
      # future orchestrator that will invoke those per item once it knows that
      # item is durably written; wiring that up is follow-up work, not this PR.
      #
      # Persisting can still fail even once an item has passed upstream guard/
      # successor validation (e.g. a write conflict on the real ActiveRecord
      # adapter) — that kind of failure can only be observed at write time, not
      # predicted in advance. Each item's persist is rescued individually so one
      # item's failure doesn't stop or lose track of the rest: the failing item
      # is recorded in Result#failed and every other item still gets persisted
      # and recorded in Result#successful, keeping Result accurate either way.
      def self.bulk_create(items)
        successful = []
        failed = []

        items.each do |item|
          item[:adapter].persist(item[:transition])
          successful << item[:object]
        rescue StandardError => e
          failed << BulkTransition::Result::FailedItem.new(object: item[:object], reason: :conflict, error: e)
        end

        BulkTransition::Result.new(successful: successful, failed: failed)
      end

      def create(from, to, metadata = {})
        from = from.to_s
        to = to.to_s
        transition = build_transition(from, to, metadata)

        @observer.execute(:before, from, to, transition)
        persist(transition)
        @observer.execute(:after, from, to, transition)
        @observer.execute(:after_commit, from, to, transition)
        transition
      end

      # Builds an unsaved transition with the correct sort_key. No side effects — does
      # not touch history and does not fire any callbacks.
      def build_transition(from, to, metadata = {})
        transition_class.new(from.to_s, to.to_s, next_sort_key, metadata)
      end

      # Persists an already-built transition (see #build_transition). No callbacks.
      def persist(transition)
        @history << transition
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
