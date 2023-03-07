# frozen_string_literal: true

module Statesman
  module Adapters
    module TypeSafeActiveRecordQueries
      def configure_state_machine(args = {})
        transition_class = args.fetch(:transition_class)
        initial_state = args.fetch(:initial_state)

        include(
          ActiveRecordQueries::ClassMethods.new(
            transition_class: transition_class,
            initial_state: initial_state,
            most_recent_transition_alias: try(:most_recent_transition_alias),
            transition_name: try(:transition_name),
          ),
        )
      end

      def self.included(base); end
    end
  end
end
