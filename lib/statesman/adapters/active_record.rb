require_relative "../exceptions"

module Statesman
  module Adapters
    class ActiveRecord
      attr_reader :transition_class
      attr_reader :parent_model

      JSON_COLUMN_TYPES = %w(json jsonb).freeze

      def initialize(transition_class, parent_model, observer, options = {})
        serialized = serialized?(transition_class)
        column_type = transition_class.columns_hash['metadata'].sql_type
        if !serialized && !JSON_COLUMN_TYPES.include?(column_type)
          raise UnserializedMetadataError,
                "#{transition_class.name}#metadata is not serialized"
        elsif serialized && JSON_COLUMN_TYPES.include?(column_type)
          raise IncompatibleSerializationError,
                "#{transition_class.name}#metadata column type cannot be json
                  and serialized simultaneously"
        end
        @transition_class = transition_class
        @parent_model = parent_model
        @observer = observer
        @association_name =
          options[:association_name] || @transition_class.table_name
      end

      def create(from, to, metadata = {})
        create_transition(from.to_s, to.to_s, metadata)
      rescue ::ActiveRecord::RecordNotUnique => e
        raise TransitionConflictError, e.message if transition_conflict_error? e
        raise
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
        transition_attributes = { to_state: to,
                                  sort_key: next_sort_key,
                                  metadata: metadata }

        transition_attributes.merge!(most_recent: true) if most_recent_column?

        transition = transitions_for_parent.build(transition_attributes)

        ::ActiveRecord::Base.transaction do
          unset_old_most_recent
          @observer.execute(:before, from, to, transition)
          transition.save!
          @last_transition = transition
          @observer.execute(:after, from, to, transition)
        end
        @observer.execute(:after_commit, from, to, transition)

        transition
      end

      def transitions_for_parent
        @parent_model.send(@association_name)
      end

      def unset_old_most_recent
        return unless most_recent_column?
        transitions_for_parent.update_all(most_recent: false)
      end

      def most_recent_column?
        transition_class.columns_hash.include?("most_recent")
      end

      def next_sort_key
        (last && last.sort_key + 10) || 0
      end

      def serialized?(transition_class)
        if ::ActiveRecord.respond_to?(:gem_version) &&
           ::ActiveRecord.gem_version >= Gem::Version.new('4.2.0.a')
          transition_class.columns_hash["metadata"].
            cast_type.is_a?(::ActiveRecord::Type::Serialized)
        else
          transition_class.serialized_attributes.include?("metadata")
        end
      end

      def transition_conflict_error?(e)
        e.message.include?(@transition_class.table_name) &&
          (e.message.include?('sort_key') || e.message.include?('most_recent'))
      end
    end
  end
end
