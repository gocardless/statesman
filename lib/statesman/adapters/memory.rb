# frozen_string_literal: true

require "json"
require_relative "../bulk_transition"

module Statesman
  module Adapters
    class Memory
      attr_reader :transition_class
      attr_reader :parent_model
      attr_reader :observer

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
      # take each object's own adapter instead. Guard failures never reach here — that
      # validation always happens upstream, in BulkTransition#run_guards, before an item
      # gets this far.
      #
      # items: an Enumerable of { object:, adapter:, metadata: }, where `adapter` is
      # that object's own Adapters::Memory instance. Runs build -> before -> persist ->
      # after -> after_commit for every item in turn, each phase rescued individually
      # (except where documented) so one item's failure doesn't stop or lose track of
      # the rest.
      #
      # before/after/after_commit are dispatched via each item's own adapter#observer —
      # the very same Machine instance the single-object #create above already calls
      # back through — not a separate callback lookup reimplemented here. Memory has no
      # real transactions, so unlike Adapters::ActiveRecord there's nothing to batch and
      # nothing to isolate: after/after_commit just run immediately, right where
      # they're dispatched.
      #
      # `conflict_retry_attempts:` is accepted (and ignored) purely for interface parity
      # with Adapters::ActiveRecord — this adapter has no chunked write to retry.
      def self.bulk_create(items, from:, to:, on_failure: :collect, skip_before_callbacks: false,
                           skip_after_callbacks: false, skip_after_commit_callbacks: false,
                           conflict_retry_attempts: nil) # rubocop:disable Lint/UnusedMethodArgument
        from = from.to_s
        to = to.to_s
        successful = []
        failed = []

        items.each do |item|
          bulk_create_one(item, from, to, on_failure, skip_before_callbacks, skip_after_callbacks,
                          skip_after_commit_callbacks, successful, failed)
        end

        BulkTransition::Result.new(successful: successful, failed: failed)
      end

      def self.bulk_create_one(item, from, to, on_failure, skip_before_callbacks, skip_after_callbacks,
                               skip_after_commit_callbacks, successful, failed)
        transition = build_for_bulk(item, from, to, failed)
        return unless transition
        return if !skip_before_callbacks && !run_before_for_bulk(item, from, to, transition, on_failure, failed)
        return unless persist_for_bulk(item, transition, successful, failed)

        run_after_for_bulk(item, from, to, transition, on_failure, failed) unless skip_after_callbacks
        item[:adapter].observer.execute(:after_commit, from, to, transition) unless skip_after_commit_callbacks
      end
      private_class_method :bulk_create_one

      def self.build_for_bulk(item, from, to, failed)
        item[:adapter].build_transition(from, to, item[:metadata])
      rescue StandardError => e
        failed << BulkTransition::Result::FailedItem.new(object: item[:object], reason: :build_transition, error: e)
        nil
      end
      private_class_method :build_for_bulk

      def self.run_before_for_bulk(item, from, to, transition, on_failure, failed)
        item[:adapter].observer.execute(:before, from, to, transition)
        true
      rescue StandardError => e
        raise if on_failure == :raise

        failed << BulkTransition::Result::FailedItem.new(object: item[:object], reason: :before_callback, error: e)
        false
      end
      private_class_method :run_before_for_bulk

      def self.persist_for_bulk(item, transition, successful, failed)
        item[:adapter].persist(transition)
        successful << item[:object]
        true
      rescue StandardError => e
        failed << BulkTransition::Result::FailedItem.new(object: item[:object], reason: :conflict, error: e)
        false
      end
      private_class_method :persist_for_bulk

      def self.run_after_for_bulk(item, from, to, transition, on_failure, failed)
        item[:adapter].observer.execute(:after, from, to, transition)
      rescue StandardError => e
        raise if on_failure == :raise

        failed << BulkTransition::Result::FailedItem.new(object: item[:object], reason: :after_callback, error: e)
      end
      private_class_method :run_after_for_bulk

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
