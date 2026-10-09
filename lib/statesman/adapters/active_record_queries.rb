# frozen_string_literal: true

module Statesman
  module Adapters
    module ActiveRecordQueries
      def self.check_missing_methods!(base)
        missing_methods = %i[transition_class initial_state].
          reject { |m| base.respond_to?(m) }
        return if missing_methods.none?

        raise NotImplementedError,
              "#{missing_methods.join(', ')} method(s) should be defined on " \
              "the model. Alternatively, use the new form of `include " \
              "Statesman::Adapters::ActiveRecordQueries[" \
              "transition_class: MyTransition, " \
              "initial_state: :some_state]`"
      end

      def self.included(base)
        check_missing_methods!(base)

        base.include(
          ClassMethods.new(
            transition_class: base.transition_class,
            initial_state: base.initial_state,
            most_recent_transition_alias: base.try(:most_recent_transition_alias),
            transition_name: base.try(:transition_name),
          ),
        )
      end

      def self.[](**args)
        ClassMethods.new(**args)
      end

      # Finds the has_many association on model that targets transition_class -
      # matching by klass rather than by name, since callers (e.g.
      # ConfigureCachedCurrentState) may not know what the association was named.
      def self.transition_reflection_for(model, transition_class)
        model.reflect_on_all_associations(:has_many).find do |reflection|
          reflection.klass == transition_class
        end || raise(
          MissingTransitionAssociation,
          "Could not find has_many association between #{model} and #{transition_class}.",
        )
      end

      class ClassMethods < Module
        def initialize(**args)
          @args = args
        end

        def included(base)
          ensure_inheritance(base) if base.respond_to?(:subclasses) && base.subclasses.any?

          query_builder = QueryBuilder.new(
            base,
            transition_class: @args[:transition_class],
            initial_state: @args[:initial_state],
            most_recent_transition_alias: @args[:most_recent_transition_alias],
            transition_name: @args[:transition_name],
          )

          base.define_singleton_method(:most_recent_transition_join) do
            query_builder.most_recent_transition_join
          end

          define_in_state(base, query_builder)
          define_not_in_state(base, query_builder)
          define_bulk_transition_to!(base)

          define_method(:reload) do |*a|
            instance = super(*a)
            if instance.respond_to?(:state_machine, true)
              instance.send(:state_machine).reset
            end
            instance
          end
        end

        private

        def ensure_inheritance(base)
          klass = self
          existing_inherited = base.method(:inherited)
          base.define_singleton_method(:inherited) do |subclass|
            existing_inherited.call(subclass)
            subclass.send(:include, klass)
          end
        end

        def define_in_state(base, query_builder)
          base.define_singleton_method(:in_state) do |*states|
            states = states.flatten

            relation = joins(most_recent_transition_join).
              where(query_builder.states_where(states), states)

            # Tags the relation with the state(s) it was built from, purely so a chained
            # .bulk_transition_to! can read back what .in_state was called with (see
            # #define_bulk_transition_to!) — Rails relations don't expose that otherwise.
            # No effect on this relation's own query/results.
            from_states = states.map(&:to_s)
            relation.extending(Module.new { define_method(:bulk_transition_from_states) { from_states } })
          end
        end

        def define_not_in_state(base, query_builder)
          base.define_singleton_method(:not_in_state) do |*states|
            states = states.flatten

            joins(most_recent_transition_join).
              where("NOT (#{query_builder.states_where(states)})", states)
          end
        end

        # Model.in_state(:x).bulk_transition_to!(:y, ...) — reached via Rails' usual
        # relation-delegates-unknown-method-back-to-class mechanism (`scoping`), so inside
        # this method `self` is the model class and `current_scope` is the exact tagged
        # relation .in_state returned (see #define_in_state). Reuses
        # Statesman::BulkTransition.call/Adapters::ActiveRecord::BulkCreate entirely for the
        # actual write — this is pure composition on top, no new write mechanics.
        #
        # machine_method: defaults to the established #state_machine convention (every
        # fixture in spec/support/active_record.rb and the README's own example define one)
        # rather than requiring new include-time configuration; override it for a model with
        # more than one state machine (e.g. #state_machine_a/#state_machine_b).
        def define_bulk_transition_to!(base)
          class_methods = self

          base.define_singleton_method(:bulk_transition_to!) do |new_state, batch_size: 100,
                                                                 machine_method: :state_machine,
                                                                 **bulk_transition_options|
            class_methods.send(:validate_bulk_transition_to!, batch_size: batch_size,
                                                              machine_method: machine_method, base: self)

            scope = current_scope
            from_state = class_methods.send(:bulk_transition_from_state, scope)
            primary_key_name = primary_key
            ids = scope.pluck(primary_key_name)

            results = ids.each_slice(batch_size).map do |id_batch|
              # unscoped, not current_scope re-applied: a row that left the in_state scope
              # between the snapshot read above and this chunk's hydration must still be
              # included here, so BulkCreate's existing staleness check (built in WU3)
              # reports it as :conflict instead of it silently vanishing from the batch
              # unreported.
              items = unscoped.where(primary_key_name => id_batch).map do |record|
                Statesman::BulkTransition::Item.new(machine: record.send(machine_method))
              end
              Statesman::BulkTransition.call(items, from_state: from_state, to_state: new_state,
                                                    **bulk_transition_options)
            end

            Statesman::BulkTransition::Result.new(
              successful: results.flat_map(&:successful),
              failed: results.flat_map(&:failed),
            )
          end
        end

        def validate_bulk_transition_to!(batch_size:, machine_method:, base:)
          unless batch_size.is_a?(Integer) && batch_size.positive?
            raise ArgumentError, "batch_size must be a positive integer, got: #{batch_size.inspect}"
          end

          return if base.method_defined?(machine_method) || base.private_method_defined?(machine_method)

          raise NotImplementedError, "#{base} must define a ##{machine_method} method returning its " \
                                     "Statesman::Machine instance to use .bulk_transition_to!"
        end

        # scope is current_scope at the point .bulk_transition_to! was called — see
        # #define_in_state for how it comes to carry bulk_transition_from_states at all.
        def bulk_transition_from_state(scope)
          unless scope.respond_to?(:bulk_transition_from_states) && scope.bulk_transition_from_states.one?
            raise ArgumentError, "bulk_transition_to! must be called on a relation built via " \
                                 "in_state(:a_single_state)"
          end

          scope.bulk_transition_from_states.first
        end
      end

      class QueryBuilder
        def initialize(model, transition_class:, initial_state:,
                       most_recent_transition_alias: nil,
                       transition_name: nil)
          @model = model
          @transition_class = transition_class
          @initial_state = initial_state
          @most_recent_transition_alias = most_recent_transition_alias
          @transition_name = transition_name
        end

        def states_where(states)
          if initial_state.to_s.in?(states.map(&:to_s))
            "#{most_recent_transition_alias}.to_state IN (?) OR " \
              "#{most_recent_transition_alias}.to_state IS NULL"
          else
            "#{most_recent_transition_alias}.to_state IN (?) AND " \
              "#{most_recent_transition_alias}.to_state IS NOT NULL"
          end
        end

        def most_recent_transition_join
          "LEFT OUTER JOIN #{model_table} AS #{most_recent_transition_alias} " \
            "ON #{model.table_name}.#{model_primary_key} = " \
            "#{most_recent_transition_alias}.#{model_foreign_key} " \
            "AND #{most_recent_transition_alias}.most_recent = #{db_true}"
        end

        private

        attr_reader :model, :transition_class, :initial_state

        def transition_name
          @transition_name || transition_class.table_name.to_sym
        end

        def transition_reflection
          ActiveRecordQueries.transition_reflection_for(model, transition_class)
        end

        def model_primary_key
          transition_reflection.active_record_primary_key
        end

        def model_foreign_key
          transition_reflection.foreign_key
        end

        def model_table
          transition_reflection.table_name
        end

        def most_recent_transition_alias
          @most_recent_transition_alias ||
            "most_recent_#{transition_name.to_s.singularize}"
        end

        def db_true
          model.connection.quote(true)
        end
      end
    end
  end
end
