require "json"
require "active_record"

module Statesman
  module Adapters
    class ActiveRecord
      attr_reader :transition_class
      attr_reader :parent_model

      def initialize(transition_class, parent_model)
        transition_class.send(:serialize, :metadata, JSON)
        @transition_class = transition_class
        @parent_model = parent_model
      end

      def create(to, before_cbs, after_cbs, metadata = {})
        transition = transitions_for_parent.build(to_state: to,
                                                  sort_key: next_sort_key,
                                                  metadata: metadata)

        ::ActiveRecord::Base.transaction do
          before_cbs.each { |cb| cb.call(@parent_model, transition) }
          transition.save!
          after_cbs.each { |cb| cb.call(@parent_model, transition) }
        end

        transition
      end

      def history
        transitions_for_parent.order(:created_at)
      end

      def last
        transitions_for_parent.order(:sort_key).last
      end

      private

      def transitions_for_parent
        @parent_model.send(@transition_class.table_name)
      end

      def next_sort_key
        (last && last.sort_key + 10) || 0
      end
    end
  end
end
