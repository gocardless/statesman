# frozen_string_literal: true

require_relative "../../bulk_transition"
require_relative "uniform_adapter"

module Statesman
  module Adapters
    class ActiveRecord
      # The real implementation behind Adapters::ActiveRecord.build_transitions — see
      # that method for the full contract (what `items` is and why batching this helps).
      #
      # One instance per call. Reads every parent's current most_recent row in one
      # query — id unused here (see BulkCreate, which needs it to flip), just sort_key
      # (this transition's basis) and to_state. That same read doubles as this class's
      # only conflict check: `from` is only available here, not in .bulk_create's items
      # (whose entries carry an already-built transition, not the from/to pair that
      # built it) — a parent whose most recent to_state no longer matches the item's
      # `from` has already moved on since this call's items were decided (e.g. a stale
      # read upstream of BulkTransition itself), and is failed as :conflict before a
      # transition is even built for it, with no row ever touched.
      #
      # This is a snapshot, not a lock — a genuine *concurrent* write landing between
      # this read and .bulk_create's later flip is a separate, later concern, caught by
      # that call's own re-read (see BulkCreate#flip_and_partition) regardless of
      # anything decided here.
      class BuildTransitions
        include UniformAdapter

        def self.call(items)
          new(items).call
        end

        def initialize(items)
          @items = items
        end

        def call
          return [[], []] if items.empty?

          assert_uniform_adapter!

          parent_ids = items.map { |item| item[:object].id }
          @current_rows = most_recent_rows_for(parent_ids)

          entries = []
          failed = []
          items.each { |item| process_item(item, entries, failed) }

          [entries, failed]
        end

        private

        attr_reader :items, :current_rows

        def process_item(item, entries, failed)
          row = current_rows[item[:object].id]

          if row && row[:to_state] != item[:from]
            failed << conflict(item, row)
          else
            build_entry(item, row, entries)
          end
        rescue StandardError => e
          failed << BulkTransition::Result::FailedItem.new(object: item[:object], reason: :build_transition, error: e)
        end

        def build_entry(item, row, entries)
          transition = item[:adapter].build_transition(item[:from], item[:to], item[:metadata])
          transition.assign_attributes(sort_key: row ? row[:sort_key] + 10 : 10, most_recent: true)

          entries << { object: item[:object], adapter: item[:adapter], transition: transition,
                       most_recent_id: row && row[:id] }
        end

        def conflict(item, row)
          error = Statesman::TransitionConflictError.new(
            "#{item[:object].class} #{item[:object].id.inspect} is no longer in state " \
            "#{item[:from].inspect} (now #{row[:to_state].inspect})",
          )
          BulkTransition::Result::FailedItem.new(object: item[:object], reason: :conflict, error: error)
        end
      end
    end
  end
end
