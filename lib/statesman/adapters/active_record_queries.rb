module Statesman
  module Adapters
    module ActiveRecordQueries
      def self.check_missing_methods!(base)
        missing_methods = %i[transition_class initial_state].
          reject { |m| base.respond_to?(m) }
        return if missing_methods.none?

        raise NotImplementedError,
              "#{missing_methods.join(', ')} method(s) should be defined on " \
              "the model. Alternatively, use the new form of `extend " \
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
          ensure_inheritance(base)

          query_builder = QueryBuilder.new(base, **@args)

          base.define_singleton_method(:most_recent_transition_join) do
            query_builder.most_recent_transition_join
          end

          define_in_state(base, query_builder)
          define_not_in_state(base, query_builder)
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
            states = states.flatten.map(&:to_s)

            joins(most_recent_transition_join).
              where(query_builder.states_where(states), states)
          end
        end

        def define_not_in_state(base, query_builder)
          base.define_singleton_method(:not_in_state) do |*states|
            states = states.flatten.map(&:to_s)

            joins(most_recent_transition_join).
              where("NOT (#{query_builder.states_where(states)})", states)
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
          if initial_state.to_s.in?(states.map(&:to_s))
            "#{most_recent_transition_alias}.to_state IN (?) OR " \
            "#{most_recent_transition_alias}.to_state IS NULL"
          else
            "#{most_recent_transition_alias}.to_state IN (?) AND " \
            "#{most_recent_transition_alias}.to_state IS NOT NULL"
          end
        end

        def most_recent_transition_join
          "LEFT OUTER JOIN #{model_table} AS #{most_recent_transition_alias}
             ON #{model.table_name}.id =
                  #{most_recent_transition_alias}.#{model_foreign_key}
             AND #{most_recent_transition_alias}.most_recent = #{db_true}"
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
          ::ActiveRecord::Base.connection.quote(true)
        end
      end
    end
  end
end
