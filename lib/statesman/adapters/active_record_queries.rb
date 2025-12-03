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

      class ClassMethods < Module
        def initialize(**args)
          @args = args
        end

        def included(base)
          ensure_inheritance(base) if base.respond_to?(:subclasses) && base.subclasses.any?

          query_builder = QueryBuilder.new(base, **@args)

          base.define_singleton_method(:most_recent_transition_join) do
            query_builder.most_recent_transition_join
          end

          define_in_state(base, query_builder)
          define_not_in_state(base, query_builder)

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

            joins(most_recent_transition_join).
              where(query_builder.states_where(states))
          end
        end

        def define_not_in_state(base, query_builder)
          base.define_singleton_method(:not_in_state) do |*states|
            states = states.flatten

            joins(most_recent_transition_join).
              where(query_builder.states_where(states).not)
          end
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
          transition_table = transition_class.arel_table
          aliased_table = transition_table.alias(most_recent_transition_alias)
          to_state_column = aliased_table[:to_state]

          in_states = to_state_column.in(states)

          if initial_state.to_s.in?(states.map(&:to_s))
            in_states.or(to_state_column.eq(nil))
          else
            in_states.and(to_state_column.not_eq(nil))
          end
        end

        def most_recent_transition_join
          transition_table = transition_class.arel_table
          aliased_table = transition_table.alias(most_recent_transition_alias)

          join_condition = model.arel_table[model_primary_key].
            eq(aliased_table[model_foreign_key]).
            and(aliased_table[:most_recent].eq(true))

          model.arel_table.
            join(aliased_table, Arel::Nodes::OuterJoin).
            on(join_condition).
            join_sources
        end

        private

        attr_reader :model, :transition_class, :initial_state

        def transition_name
          @transition_name || transition_class.table_name.to_sym
        end

        def transition_reflection
          model.reflect_on_all_associations(:has_many).each do |value|
            return value if value.klass == transition_class
          end

          raise MissingTransitionAssociation,
                "Could not find has_many association between #{self.class} " \
                "and #{transition_class}."
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
      end
    end
  end
end
