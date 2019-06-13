require_relative "../exceptions"

module Statesman
  module Adapters
    class ActiveRecord
      attr_reader :transition_class
      attr_reader :parent_model

      JSON_COLUMN_TYPES = %w[json jsonb].freeze

      def self.database_supports_partial_indexes?
        # Rails 3 doesn't implement `supports_partial_index?`
        if ::ActiveRecord::Base.connection.respond_to?(:supports_partial_index?)
          ::ActiveRecord::Base.connection.supports_partial_index?
        else
          ::ActiveRecord::Base.connection.adapter_name == "PostgreSQL"
        end
      end

      def initialize(transition_class, parent_model, observer, options = {})
        serialized = serialized?(transition_class)
        column_type = transition_class.columns_hash["metadata"].sql_type
        if !serialized && !JSON_COLUMN_TYPES.include?(column_type)
          raise UnserializedMetadataError, transition_class.name
        elsif serialized && JSON_COLUMN_TYPES.include?(column_type)
          raise IncompatibleSerializationError, transition_class.name
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

      def history(force_reload: false)
        if transitions_for_parent.loaded? && !force_reload
          # Workaround for Rails bug which causes infinite loop when sorting
          # already loaded result set. Introduced in rails/rails@b097ebe
          transitions_for_parent.to_a.sort_by(&:sort_key)
        else
          transitions_for_parent.order(:sort_key)
        end
      end

      def last(force_reload: false)
        if force_reload
          @last_transition = history(force_reload: true).last
        else
          @last_transition ||= history.last
        end
      end

      private

      # rubocop:disable Metrics/MethodLength
      def create_transition(from, to, metadata)
        transition = transitions_for_parent.build(
          default_transition_attributes(to, metadata),
        )

        ::ActiveRecord::Base.transaction(requires_new: true) do
          @observer.execute(:before, from, to, transition)

          # We save the transition first with most_recent falsy, then mark most_recent
          # true after to avoid letting MySQL acquire a next-key lock which can cause
          # deadlocks.
          #
          # To avoid an additional query, we manually adjust the most_recent attribute on
          # our transition assuming that update_most_recents will have set it to true.
          transition.save!
          unless update_most_recents(transition.id) > 0
            raise ActiveRecord::Rollback, "failed to update most_recent"
          end

          transition.assign_attributes(most_recent: true)

          @last_transition = transition
          @observer.execute(:after, from, to, transition)
          add_after_commit_callback(from, to, transition)
        end

        transition
      end
      # rubocop:enable Metrics/MethodLength

      def default_transition_attributes(to, metadata)
        transition_attributes = { to_state: to,
                                  sort_key: next_sort_key,
                                  metadata: metadata }

        # see comment on `unset_old_most_recent` method
        if transition_class.columns_hash["most_recent"].null == false
          transition_attributes[:most_recent] = false
        else
          transition_attributes[:most_recent] = nil
        end
        transition_attributes
      end

      def add_after_commit_callback(from, to, transition)
        ::ActiveRecord::Base.connection.add_transaction_record(
          ActiveRecordAfterCommitWrap.new do
            @observer.execute(:after_commit, from, to, transition)
          end,
        )
      end

      def transitions_for_parent
        parent_model.send(@association_name)
      end

      # Sets the given transition most_recent = t while unsetting the most_recent of any
      # previous transitions.
      def update_most_recents(most_recent_id)
        transitions = transitions_for_parent
        last_or_current = transitions.where(id: most_recent_id).or(
          transitions.where(most_recent: true)
        )

        last_or_current.update_all(
          build_most_recents_update_all(most_recent_id),
        )
      end

      # Generates update_all parameters that will touch the updated timestamp (if valid
      # for this model) and ensure only the transition with the most_recent_id has
      # most_recent set to true.
      #
      # This is quite nasty, but combines two updates (set all most_recent = f, set
      # current most_recent = t) into one, which helps improve transition performance
      # especially when database latency is significant.
      #
      # The SQL this can help produce looks like:
      #
      #   update transitions
      #      set most_recent = (case when id = 'PA123' then TRUE else FALSE end)
      #        , updated_at = '...'
      #      ...
      #
      def build_most_recents_update_all(most_recent_id)
        clause = "most_recent = (case when id = ? then ? else ? end)"
        parameters = [most_recent_id, true, not_most_recent_value]

        updated_column, updated_at = updated_timestamp
        if updated_column
          clause += ", #{updated_column} = ?"
          parameters.push(updated_at)
        end

        [clause, *parameters]
      end

      # Check whether the `most_recent` column allows null values. If it doesn't, set old
      # records to `false`, otherwise, set them to `NULL`.
      #
      # Some conditioning here is required to support databases that don't support partial
      # indexes. By doing the conditioning on the column, rather than Rails' opinion of
      # whether the database supports partial indexes, we're robust to DBs later adding
      # support for partial indexes.
      def not_most_recent_value
        return false if transition_class.columns_hash["most_recent"].null == false

        nil
      end

      def next_sort_key
        (last && last.sort_key + 10) || 10
      end

      def serialized?(transition_class)
        if ::ActiveRecord.respond_to?(:gem_version) &&
            ::ActiveRecord.gem_version >= Gem::Version.new("4.2.0.a")
          transition_class.type_for_attribute("metadata").
            is_a?(::ActiveRecord::Type::Serialized)
        else
          transition_class.serialized_attributes.include?("metadata")
        end
      end

      def transition_conflict_error?(err)
        return true if unique_indexes.any? { |i| err.message.include?(i.name) }

        err.message.include?(transition_class.table_name) &&
          (err.message.include?("sort_key") || err.message.include?("most_recent"))
      end

      def unique_indexes
        ::ActiveRecord::Base.connection.
          indexes(transition_class.table_name).
          select do |index|
            next unless index.unique

            index.columns.sort == [parent_join_foreign_key, "sort_key"] ||
              index.columns.sort == [parent_join_foreign_key, "most_recent"]
          end
      end

      def parent_join_foreign_key
        association =
          parent_model.class.
            reflect_on_all_associations(:has_many).
            find { |r| r.name.to_s == @association_name.to_s }

        association_join_primary_key(association)
      end

      def association_join_primary_key(association)
        if association.respond_to?(:join_primary_key)
          association.join_primary_key
        elsif association.method(:join_keys).arity.zero?
          # Support for Rails 5.1
          association.join_keys.key
        else
          # Support for Rails < 5.1
          association.join_keys(transition_class).key
        end
      end

      # updated_timestamp should return [column_name, value]
      def updated_timestamp
        # TODO: Once we've set expectations that transition classes should conform to
        # the interface of Adapters::ActiveRecordTransition as a breaking change in the
        # next major version, we can stop calling `#respond_to?` first and instead
        # assume that there is a `.updated_timestamp_column` method we can call.
        #
        # At the moment, most transition classes will include the module, but not all,
        # not least because it doesn't work with PostgreSQL JSON columns for metadata.
        column = if transition_class.respond_to?(:updated_timestamp_column)
                   transition_class.updated_timestamp_column
                 else
                   ActiveRecordTransition::DEFAULT_UPDATED_TIMESTAMP_COLUMN
                 end

        # No updated timestamp column, don't return anything
        return nil if column.nil?

        [
          column, ::ActiveRecord::Base.default_timezone == :utc ? Time.now.utc : Time.now,
        ]
      end
    end

    class ActiveRecordAfterCommitWrap
      def initialize
        @callback = Proc.new
        @connection = ::ActiveRecord::Base.connection
      end

      # rubocop: disable Naming/PredicateName
      def has_transactional_callbacks?
        true
      end
      # rubocop: enable Naming/PredicateName

      def committed!(*)
        @callback.call
      end

      def before_committed!(*); end

      def rolledback!(*); end

      # Required for +transaction(requires_new: true)+
      def add_to_transaction(*)
        @connection.add_transaction_record(self)
      end
    end
  end
end
