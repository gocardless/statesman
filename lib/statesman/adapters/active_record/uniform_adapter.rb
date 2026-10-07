# frozen_string_literal: true

module Statesman
  module Adapters
    class ActiveRecord
      # Shared by BuildTransitions and BulkCreate — both are one-instance-per-call,
      # operating on a batch of items that must all resolve to the same
      # transition_class/parent_model_class/association_name, since each produces one
      # shared set of SQL (one snapshot query, one flip UPDATE, one insert_all!) that
      # only targets the right table/foreign key if every item agrees on all three.
      # They're per-Machine-*instance* options (see Machine#initialize), not fixed per
      # Machine subclass, so bucketing by machine class upstream (see
      # BulkTransition#transition_batch) doesn't already guarantee this — it has to be
      # checked for real, against every item, here. Each including class calls this
      # itself (no shared instance survives between a .build_transitions call and the
      # later .bulk_create call for the same batch), so the check and the query below
      # both happen once per call, not once per batch overall.
      module UniformAdapter
        private

        def assert_uniform_adapter!
          transition_classes = items.map { |item| item[:adapter].transition_class }.uniq
          parent_model_classes = items.map { |item| item[:object].class }.uniq
          association_names = items.map { |item| item[:adapter].association_name }.uniq

          assert_one!("transition class", transition_classes)
          assert_one!("parent model class", parent_model_classes)
          assert_one!("association name", association_names)

          @transition_class = transition_classes.first
          @parent_model_class = parent_model_classes.first
          @foreign_key = ActiveRecord.parent_join_foreign_key(@parent_model_class, association_names.first,
                                                              @transition_class)
        end

        def assert_one!(label, values)
          return if values.one?

          raise ArgumentError, "BulkTransition requires every object to use the same #{label}, " \
                               "got: #{values.join(', ')}"
        end

        attr_reader :transition_class, :parent_model_class, :foreign_key

        # Every parent's current most_recent row, in one query: id (the flip/optimistic-
        # concurrency token), sort_key (the next transition's basis) and to_state (the
        # authoritative from_state). A parent absent from the result has no history yet.
        def most_recent_rows_for(parent_ids, columns: %i[id sort_key to_state])
          return {} if parent_ids.empty?

          scope = transition_class.where(ActiveRecord.most_recent_transitions(transition_class, foreign_key,
                                                                              parent_ids))

          scope.pluck(foreign_key, *columns).each_with_object({}) do |row, hash|
            parent_id, *values = row
            hash[parent_id] = columns.zip(values).to_h
          end
        end
      end
    end
  end
end
