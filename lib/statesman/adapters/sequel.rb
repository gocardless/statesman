require_relative "../exceptions"

module Statesman
  module Adapters
    class Sequel
      attr_reader :transition_class, :parent_model, :observer

      ::Sequel.extension(:inflector)

      def initialize(transition_class, parent_model, observer)
        @transition_class = transition_class
        @parent_model = parent_model
        @observer = observer
      end

      def create(from, to, metadata = {})
        create_transition(from.to_s, to.to_s, metadata)
      ensure
        @last_transition = nil
      end

      def history
        history_dataset.all
      end

      def last
        @last_transition ||= history_dataset.last
      end

      private

      def history_dataset
        transitions_for_parent.order(:sort_key)
      end

      def transitions_for_parent
        @parent_model.send("#{transition_table_name}_dataset")
      end

      def next_sort_key
        (last && last.sort_key + 10) || 0
      end

      def create_transition(from, to, metadata)
        transition = transition_class.new(
          to_state: to,
          sort_key: next_sort_key,
          metadata: metadata,
          parent_model_foreign_key => @parent_model.pk
        )

        parent_model_class.db.transaction do
          @observer.execute(:before, from, to, transition)
          transition.save
          @last_transition = transition
          @observer.execute(:after, from, to, transition)
        end

        @observer.execute(:after_commit, from, to, transition)

        transition
      end

      def transition_table_name
        @transition_table_name ||= @transition_class.table_name
      end

      def parent_model_class
        @parent_model_class ||= @parent_model.class
      end

      def parent_model_foreign_key
        "#{parent_model_class.table_name.to_s.singularize}_id"
      end
    end
  end
end
