module Statesman
  module Adapters
    module ActiveRecordQueries
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def in_state(*states)
          states = states.flatten.map(&:to_s)

          joins(most_recent_transition_join).
            where(states_where(most_recent_transition_alias, states), states)
        end

        def not_in_state(*states)
          states = states.flatten.map(&:to_s)

          joins(most_recent_transition_join).
            where("NOT (#{states_where(most_recent_transition_alias, states)})",
                  states)
        end

        private

        def transition_class
          raise NotImplementedError, "A transition_class method should be " \
                                     "defined on the model"
        end

        def initial_state
          raise NotImplementedError, "An initial_state method should be " \
                                     "defined on the model"
        end

        def transition_name
          transition_class.table_name.to_sym
        end

        def transition_reflection
          reflect_on_all_associations(:has_many).each do |value|
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

        def most_recent_transition_join
          "LEFT OUTER JOIN #{model_table} AS #{most_recent_transition_alias}
             ON #{table_name}.id =
                  #{most_recent_transition_alias}.#{model_foreign_key}
             AND #{most_recent_transition_alias}.most_recent = #{db_true}"
        end

        def states_where(temporary_table_name, states)
          if initial_state.to_s.in?(states.map(&:to_s))
            "#{temporary_table_name}.to_state IN (?) OR " \
            "#{temporary_table_name}.to_state IS NULL"
          else
            "#{temporary_table_name}.to_state IN (?) AND " \
            "#{temporary_table_name}.to_state IS NOT NULL"
          end
        end

        def most_recent_transition_alias
          "most_recent_#{transition_name.to_s.singularize}"
        end

        def db_true
          ::ActiveRecord::Base.connection.quote(true)
        end
      end
    end
  end
end
