require "json"
require "active_record"

module Statesman
  module Adapters
    class ActiveRecord
      attr_reader :transition_class
      attr_reader :parent_model

      def initialize(transition_class, parent_model)
        @transition_class = transition_class
        @parent_model = parent_model
      end

      def create(to, metadata = nil)
        transition = transitions_for_parent.create(to_state: to,
                                                   sort_key: next_sort_key)

        conditionally_set_metadata(transition, metadata)
        save_in_transaction(transition, parent_model)

        transition
      end

      def history
        transitions_for_parent.order(:created_at)
      end

      def last
        transitions_for_parent.order(:sort_key).last
      end

      private

      def save_in_transaction(*args)
        ::ActiveRecord::Base.transaction { args.each(&:save!) }
      end

      def transitions_for_parent
        @parent_model.send(@transition_class.table_name)
      end

      def conditionally_set_metadata(transition, metadata)
        if transition.respond_to?(:metadata=)
          transition.metadata = metadata.to_json unless metadata.nil?
        end
      end

      def next_sort_key
        (last && last.sort_key + 10) || 0
      end
    end
  end
end
