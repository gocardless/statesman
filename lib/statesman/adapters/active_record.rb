require "active_record"

module Statesman
  module Adapters
    class ActiveRecord
      attr_reader :transition_class
      attr_reader :parent_model
      attr_reader :state_attr

      def initialize(transition_class, parent_model, state_attr)
        @transition_class = transition_class
        @parent_model = parent_model
        @state_attr = state_attr
      end

      def create(from, to, metadata = nil)
        transition = transitions_for_parent.create(from: from, to: to)
        conditionally_set_metadata(transition, metadata)

        parent_model.send("#{state_attr}=", to)
        save_in_transaction(transition, parent_model)

        transition
      end

      def history
        transitions_for_parent.order(:created_at)
      end

      def last
        transitions_for_parent.order(:created_at).last
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
    end
  end
end
