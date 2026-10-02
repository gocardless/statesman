# frozen_string_literal: true

require_relative "../exceptions"
require_relative "../bulk_transition"
require_relative "active_record/bulk_create"

module Statesman
  module Adapters
    class ActiveRecord
      JSON_COLUMN_TYPES = %w[json jsonb].freeze

      def self.database_supports_partial_indexes?(model)
        # Rails 3 doesn't implement `supports_partial_index?`
        if model.connection.respond_to?(:supports_partial_index?)
          model.connection.supports_partial_index?
        else
          model.connection.adapter_name.casecmp("postgresql").zero?
        end
      end

      # Batched write path behind Statesman::BulkTransition.call — see BulkCreate for
      # the full contract and mechanics, including why building, before/after/
      # after_commit dispatch, and persisting are all this one call's job rather than
      # split across several adapter methods the orchestrator calls in sequence.
      # `items` is an Enumerable of { object:, adapter:, metadata: }, all sharing one
      # bucket's `from`/`to` state. `model_validations:` governs BulkCreate's choice
      # between its fast `insert_all!` write path and a `save!`-loop fallback — see
      # BulkTransition for the option's full contract.
      def self.bulk_create(items, from:, to:, on_failure: :collect, skip_before_callbacks: false,
                           skip_after_callbacks: false, skip_after_commit_callbacks: false,
                           model_validations: :auto)
        BulkCreate.call(items, from: from, to: to, on_failure: on_failure,
                               skip_before_callbacks: skip_before_callbacks,
                               skip_after_callbacks: skip_after_callbacks,
                               skip_after_commit_callbacks: skip_after_commit_callbacks,
                               model_validations: model_validations)
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
        @transition_table = transition_class.arel_table
        @parent_model = parent_model
        @observer = observer
        @association_name =
          options[:association_name] || @transition_class.table_name
      end

      attr_reader :transition_class, :transition_table, :parent_model, :association_name, :observer

      def create(from, to, metadata = {})
        create_transition(from.to_s, to.to_s, metadata)
      rescue ::ActiveRecord::RecordNotUnique => e
        if transition_conflict_error? e
          # The history has the invalid transition on the end of it, which means
          # `current_state` would then be incorrect. We force a reload of the history to
          # avoid this.
          transitions_for_parent.reload
          raise TransitionConflictError, e.message
        end

        raise
      ensure
        reset
      end

      # Builds an unsaved transition, with no callbacks run — the counterpart to
      # Adapters::Memory#build_transition, used by Statesman::BulkTransition's write path.
      #
      # Deliberately does not set `sort_key` (unlike #default_transition_attributes, used
      # by the single-object #create_transition, which always calls #next_sort_key). This
      # method is called once per object, *before* any batching happens — if it queried for
      # the current sort key itself, that would be one query per object again, defeating
      # the entire point of batching before a single row is even persisted.
      # Adapters::ActiveRecord.bulk_create computes every survivor's real `sort_key` from
      # one batched read instead (see #most_recent_rows_for), and assigns it there.
      def build_transition(from, to, metadata = {})
        attributes = {
          to_state: to.to_s,
          metadata: metadata,
          most_recent: not_most_recent_value(db_cast: false),
        }
        attributes[:from_state] = from.to_s if @transition_class.has_attribute?(:from_state)

        transitions_for_parent.build(attributes)
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
        elsif instance_variable_defined?(:@last_transition)
          @last_transition
        else
          @last_transition = history.last
        end
      end

      # Runs the given block only once genuinely committed, via the same
      # ActiveRecordAfterCommitWrap/connection.add_transaction_record machinery
      # #add_after_commit_callback below already uses for the single-object write path —
      # this just exposes it as a public seam. Used by Adapters::ActiveRecord::BulkCreate
      # from inside its own chunk write transaction (the only point one is guaranteed
      # open), so a bulk `after_commit` callback gets the same guarantee the
      # single-object path already has: it only fires once the real, outermost
      # transaction commits — this chunk's own if nothing wraps the call, or an outer
      # one the caller holds around the whole BulkTransition.call.
      #
      # Deliberately decoupled from whether this item's own `after` callbacks (see
      # #with_own_transaction) succeed — by design, for bulk, `after_commit`'s guarantee
      # is "the transition itself is durable", not "and every cascading `after` side
      # effect also succeeded". Making the latter true would mean either holding this
      # chunk's write transaction open across every item's `after` suite (bad — see
      # BulkCreate), or serializing after_commit's firing behind N separate outcomes,
      # neither of which this method has any way to know about from here.
      def defer_until_committed(&block)
        transition_class.connection.add_transaction_record(
          ActiveRecordAfterCommitWrap.new(transition_class.connection, &block),
        )
      end

      # Runs the given block in its own transaction, isolated from whichever other
      # items share this chunk's write (see Adapters::ActiveRecord::BulkCreate
      # #dispatch_after_callbacks_for). Used for one item's `after` callbacks
      # specifically: they can be arbitrary, cascading application writes (e.g.
      # creating audit events, cancelling related records) that a caller reasonably
      # wants atomic with *each other*, without risking a raise mid-chunk rolling back
      # every other item's already-good insert — impossible if `after` ran inside the
      # chunk's own shared transaction instead, and unacceptably slow if the chunk's
      # transaction stayed open for every item's `after` suite one after another.
      # requires_new: true so this is always a real, independently committable/
      # rollback-able unit, whether or not the caller already has an outer transaction
      # open.
      def with_own_transaction(&block)
        transition_class.transaction(requires_new: true, &block)
      end

      def reset
        if instance_variable_defined?(:@last_transition)
          remove_instance_variable(:@last_transition)
        end
      end

      # Public (not private) because Adapters::ActiveRecord::BulkCreate, a sibling class
      # with no instance of its own, needs these — they used to be private and reached
      # via `adapter.send(...)`. Each is a thin wrapper around the class method of the
      # same name below, which does the real work as a pure function of
      # transition_class/parent_model_class/association_name/parent_id — none of it
      # depends on *this* adapter's specific parent_model identity. BulkCreate calls the
      # class methods directly with its own validated, uniform-across-the-batch values
      # (see UniformAdapter) instead of going through any one item's adapter instance;
      # these instance wrappers exist only for the single-object write path below
      # (`unique_indexes`, `update_most_recents`, etc.), which already has an adapter
      # instance sitting around and has no need to reach past it.
      def parent_join_foreign_key
        self.class.parent_join_foreign_key(parent_model.class, @association_name, transition_class)
      end

      def most_recent_transitions(most_recent_id = nil, parent_id = parent_model.id)
        self.class.most_recent_transitions(transition_class, parent_join_foreign_key, parent_id, most_recent_id)
      end

      def not_most_recent_value(db_cast: true)
        self.class.not_most_recent_value(transition_class, db_cast: db_cast)
      end

      def updated_column_and_timestamp
        self.class.updated_column_and_timestamp(transition_class)
      end

      class << self
        def parent_join_foreign_key(parent_model_class, association_name, transition_class)
          association = parent_model_class.
            reflect_on_all_associations(:has_many).
            find { |r| r.name.to_s == association_name.to_s }
          association_join_primary_key(association, transition_class)
        end

        def most_recent_transitions(transition_class, foreign_key, parent_id, most_recent_id = nil)
          table = transition_class.arel_table
          scope = concrete_transitions_of_parent(transition_class, foreign_key, parent_id)

          if most_recent_id
            scope.and(table[:id].eq(most_recent_id).or(table[:most_recent].eq(true)))
          else
            scope.and(table[:most_recent].eq(true))
          end
        end

        # Check whether the `most_recent` column allows null values. If it doesn't, set
        # old records to `false`, otherwise, set them to `NULL`.
        #
        # Some conditioning here is required to support databases that don't support
        # partial indexes. By doing the conditioning on the column, rather than Rails'
        # opinion of whether the database supports partial indexes, we're robust to DBs
        # later adding support for partial indexes.
        def not_most_recent_value(transition_class, db_cast: true)
          if transition_class.columns_hash["most_recent"].null == false
            return db_cast ? db_false(transition_class) : false
          end

          db_cast ? db_null : nil
        end

        def updated_column_and_timestamp(transition_class)
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

          [column, default_timezone == :utc ? Time.now.utc : Time.now]
        end

        private

        def association_join_primary_key(association, transition_class)
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

        # `parent_id` accepts either a single id (the single-object write path, via the
        # instance wrapper above) or an Array of ids (bulk_create's batched reads/writes,
        # scoped to many parents at once) — `Arel::Nodes::Node#in` vs `#eq` handles the
        # distinction.
        def concrete_transitions_of_parent(transition_class, foreign_key, parent_id)
          if transition_sti?(transition_class)
            transitions_of_parent(transition_class, foreign_key, parent_id).and(
              transition_class.arel_table[transition_class.inheritance_column].eq(transition_class.name),
            )
          else
            transitions_of_parent(transition_class, foreign_key, parent_id)
          end
        end

        def transitions_of_parent(transition_class, foreign_key, parent_id)
          column = transition_class.arel_table[foreign_key.to_sym]
          parent_id.is_a?(Array) ? column.in(parent_id) : column.eq(parent_id)
        end

        def transition_sti?(transition_class)
          transition_class.column_names.include?(transition_class.inheritance_column)
        end

        # Rails 7 deprecates ActiveRecord::Base.default_timezone in favour of
        # ActiveRecord.default_timezone
        def default_timezone
          return ::ActiveRecord.default_timezone if ::ActiveRecord.respond_to?(:default_timezone)

          ::ActiveRecord::Base.default_timezone
        end

        def db_false(transition_class)
          transition_class.connection.quote(transition_class.connection.type_cast(false))
        end

        def db_null
          Arel::Nodes::SqlLiteral.new("NULL")
        end
      end

      private

      def create_transition(from, to, metadata)
        transition = transitions_for_parent.build(
          default_transition_attributes(from, to, metadata),
        )

        transition_class.transaction(requires_new: true) do
          @observer.execute(:before, from, to, transition)

          if mysql_gaplock_protection?(transition_class.connection)
            # We save the transition first with most_recent falsy, then mark most_recent
            # true after to avoid letting MySQL acquire a next-key lock which can cause
            # deadlocks.
            #
            # To avoid an additional query, we manually adjust the most_recent attribute
            # on our transition assuming that update_most_recents will have set it to true

            transition.save!

            unless update_most_recents(transition.id).positive?
              raise ActiveRecord::Rollback, "failed to update most_recent"
            end

            transition.assign_attributes(most_recent: true)
          else
            update_most_recents
            transition.assign_attributes(most_recent: true)
            transition.save!
          end

          maintain_cached_current_state(transition)

          @last_transition = transition
          @observer.execute(:after, from, to, transition)
          add_after_commit_callback(from, to, transition)
        end

        transition
      end

      # Writes the cached current state column configured via
      # Statesman::Adapters::ConfigureCachedCurrentState#configure_cached_current_state,
      # if the parent model opted in. Done here, rather than via an ActiveRecord
      # callback on transition_class, so it fires reliably even under
      # mysql_gaplock_protection - where most_recent is flipped to true via a raw SQL
      # UPDATE that bypasses ActiveRecord callbacks entirely (see above). This method
      # always runs after most_recent has been set on `transition` (in both branches
      # above), and before the machine's own after_transition callbacks are invoked.
      def maintain_cached_current_state(transition)
        model_class = parent_model.class
        return unless model_class.respond_to?(:cached_state_column_name)

        column = model_class.cached_state_column_name
        unless model_class.column_names.include?(column.to_s)
          raise ArgumentError,
                "cache_current_state_column: #{column.inspect} is not a column " \
                "on #{model_class.name}"
        end

        attributes = { column => transition.to_state }
        attributes[:updated_at] = Time.current if model_class.cached_current_state_touch_updated_at?
        parent_model.update_columns(attributes)
      end

      def default_transition_attributes(from, to, metadata)
        attributes = {
          to_state: to,
          sort_key: next_sort_key,
          metadata: metadata,
          most_recent: not_most_recent_value(db_cast: false),
        }

        if @transition_class.has_attribute?(:from_state)
          attributes[:from_state] = from
        end

        attributes
      end

      def add_after_commit_callback(from, to, transition)
        defer_until_committed { @observer.execute(:after_commit, from, to, transition) }
      end

      def transitions_for_parent
        parent_model.send(@association_name)
      end

      # Sets the given transition most_recent = t while unsetting the most_recent of any
      # previous transitions.
      def update_most_recents(most_recent_id = nil)
        update = build_arel_manager(::Arel::UpdateManager, transition_class)
        update.table(transition_table)
        update.where(most_recent_transitions(most_recent_id))
        update.set(build_most_recents_update_all_values(most_recent_id))

        # MySQL will validate index constraints across the intermediate result of an
        # update. This means we must order our update to deactivate the previous
        # most_recent before setting the new row to be true.
        if mysql_gaplock_protection?(transition_class.connection)
          update.order(transition_table[:most_recent].desc)
        end

        transition_class.connection.update(update.to_sql(transition_class))
      end

      # Generates update_all Arel values that will touch the updated timestamp (if valid
      # for this model) and set most_recent to true only for the transition with a
      # matching most_recent ID.
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
      def build_most_recents_update_all_values(most_recent_id = nil)
        [
          [
            transition_table[:most_recent],
            Arel::Nodes::SqlLiteral.new(most_recent_value(most_recent_id)),
          ],
        ].tap do |values|
          # Only if we support the updated at timestamps should we add this column to the
          # update
          updated_column, updated_at = updated_column_and_timestamp

          if updated_column
            values << [
              transition_table[updated_column.to_sym],
              updated_at,
            ]
          end
        end
      end

      def most_recent_value(most_recent_id)
        if most_recent_id
          Arel::Nodes::Case.new.
            when(transition_table[:id].eq(most_recent_id)).then(db_true).
            else(not_most_recent_value).to_sql(transition_class)
        else
          Arel::Nodes::SqlLiteral.new(not_most_recent_value)
        end
      end

      # Provide a wrapper for constructing an update manager which handles a breaking API
      # change in Arel as we move into Rails >6.0.
      #
      # https://github.com/rails/rails/commit/7508284800f67b4611c767bff9eae7045674b66f
      def build_arel_manager(manager, engine)
        if manager.instance_method(:initialize).arity.zero?
          manager.new
        else
          manager.new(engine)
        end
      end

      def next_sort_key
        (last && (last.sort_key + 10)) || 10
      end

      def serialized?(transition_class)
        transition_class.type_for_attribute("metadata").
          is_a?(::ActiveRecord::Type::Serialized)
      end

      def transition_conflict_error?(err)
        return true if unique_indexes.any? { |i| err.message.include?(i.name) }

        err.message.include?(transition_class.table_name) &&
          (err.message.include?("sort_key") || err.message.include?("most_recent"))
      end

      def unique_indexes
        transition_class.connection.
          indexes(transition_class.table_name).
          select do |index|
            next unless index.unique

            # We care about the columns used in the index, but not necessarily
            # the order, which is why we sort both sides of the comparison here
            index.columns.sort == [parent_join_foreign_key, "sort_key"].sort ||
              index.columns.sort == [parent_join_foreign_key, "most_recent"].sort
          end
      end

      def mysql_gaplock_protection?(connection)
        Statesman.mysql_gaplock_protection?(connection)
      end

      def db_true
        transition_class.connection.quote(type_cast(true))
      end

      # Type casting against a column is deprecated and will be removed in Rails 6.2.
      # See https://github.com/rails/arel/commit/6160bfbda1d1781c3b08a33ec4955f170e95be11
      def type_cast(value)
        transition_class.connection.type_cast(value)
      end
    end

    class ActiveRecordAfterCommitWrap
      def initialize(connection, &block)
        @callback = block
        @connection = connection
      end

      def self.trigger_transactional_callbacks?
        true
      end

      def trigger_transactional_callbacks?
        true
      end

      def has_transactional_callbacks?
        true
      end

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
