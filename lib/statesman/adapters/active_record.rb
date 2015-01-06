require_relative "../exceptions"

module Statesman
  module Adapters
    class ActiveRecord
      attr_reader :transition_class
      attr_reader :parent_model

      def initialize(transition_class, parent_model, observer)
        serialized = serialized?(transition_class)
        column_type = transition_class.columns_hash['metadata'].sql_type
        if !serialized && column_type != 'json'
          raise UnserializedMetadataError,
                "#{transition_class.name}#metadata is not serialized"
        elsif serialized && column_type == 'json'
          raise IncompatibleSerializationError,
                "#{transition_class.name}#metadata column type cannot be json
                  and serialized simultaneously"
        end
        @transition_class = transition_class
        @parent_model = parent_model
        @observer = observer
      end

      def create(from, to, metadata = {})
        from = from.to_s
        to = to.to_s
        create_transition(from, to, metadata)
      rescue ::ActiveRecord::RecordNotUnique => e
        if e.message.include?('sort_key') &&
           e.message.include?(@transition_class.table_name)
          raise TransitionConflictError, e.message
        else raise
        end
      ensure
        @last_transition = nil
      end

      def history
        if transitions_for_parent.loaded?
          # Workaround for Rails bug which causes infinite loop when sorting
          # already loaded result set. Introduced in rails/rails@b097ebe
          transitions_for_parent.to_a.sort_by(&:sort_key)
        else
          transitions_for_parent.order(:sort_key)
        end
      end

      def last
        @last_transition ||= history.last
      end

      private

      def create_transition(from, to, metadata)
        transition = transitions_for_parent.build(to_state: to,
                                                  sort_key: next_sort_key,
                                                  metadata: metadata)

        ::ActiveRecord::Base.transaction do
          @observer.execute(:before, from, to, transition)
          transition.save!
          @last_transition = transition
          @observer.execute(:after, from, to, transition)
        end
        @observer.execute(:after_commit, from, to, transition)

        transition
      end

      def transitions_for_parent
        @parent_model.send(@transition_class.table_name)
      end

      def next_sort_key
        (last && last.sort_key + 10) || 0
      end

      def serialized?(transition_class)
        if ::ActiveRecord.respond_to?(:gem_version) &&
           ::ActiveRecord.gem_version >= Gem::Version.new('4.2.0.a')
          transition_class.columns_hash["metadata"]
            .cast_type.is_a?(::ActiveRecord::Type::Serialized)
        else
          transition_class.serialized_attributes.include?("metadata")
        end
      end
    end
  end
end
