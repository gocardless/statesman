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
      # after_persist/after_commit are invoked once per item, immediately after that
      # item is persisted — the caller supplies *what* to run (its own `after`/
      # `after_commit` dispatch); the adapter only owns *when* it's safe to call it. For
      # Memory that's trivially "right away", since there's no transaction to protect.
      def self.bulk_create(items, after_persist: nil, after_commit: nil)
        transitioned = []

        items.each do |item|
          item[:adapter].persist(item[:transition])
          after_persist&.call(item[:object], item[:transition])
          after_commit&.call(item[:object], item[:transition])
          transitioned << item[:object]
        end

        BulkTransition::Result.new(transitioned: transitioned)
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
