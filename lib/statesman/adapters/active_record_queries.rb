module Statesman
  module Adapters
    module ActiveRecordQueries
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def in_state(*states)
          states = states.flatten.map(&:to_s)

          if use_most_recent_column?
            in_state_with_most_recent(states)
          else
            in_state_without_most_recent(states)
          end
        end

        def not_in_state(*states)
          states = states.flatten.map(&:to_s)

          if use_most_recent_column?
            not_in_state_with_most_recent(states)
          else
            not_in_state_without_most_recent(states)
          end
        end

        private

        def in_state_with_most_recent(states)
          joins(most_recent_transition_join).
            where(states_where(most_recent_transition_alias, states), states)
        end

        def not_in_state_with_most_recent(states)
          joins(most_recent_transition_join).
            where("NOT (#{states_where(most_recent_transition_alias, states)})",
                  states)
        end

        def in_state_without_most_recent(states)
          joins(transition1_join).
            joins(transition2_join).
            where(states_where(most_recent_transition_alias, states), states).
            where("#{other_transition_alias}.id" => nil)
        end

        def not_in_state_without_most_recent(states)
          joins(transition1_join).
            joins(transition2_join).
            where("NOT (#{states_where(most_recent_transition_alias, states)})",
                  states).
            where("#{other_transition_alias}.id" => nil)
        end

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
          reflect_on_association(transition_name)
        end

        def model_foreign_key
          transition_reflection.foreign_key
        end

        def model_table
          transition_reflection.table_name
        end

        def transition1_join
          "LEFT OUTER JOIN #{model_table} #{most_recent_transition_alias}
             ON #{most_recent_transition_alias}.#{model_foreign_key} =
                  #{table_name}.id"
        end

        def transition2_join
          "LEFT OUTER JOIN #{model_table} #{other_transition_alias}
             ON #{other_transition_alias}.#{model_foreign_key} =
                  #{table_name}.id
             AND #{other_transition_alias}.sort_key >
                   #{most_recent_transition_alias}.sort_key"
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

        def other_transition_alias
          "other_#{transition_name.to_s.singularize}"
        end

        def db_true
          ::ActiveRecord::Base.connection.quote(true)
        end

        # Only use the most_recent column if it has a unique index guaranteeing
        # it has good data
        def use_most_recent_column?
          ::ActiveRecord::Base.connection.index_exists?(
            transition_class.table_name,
            [model_foreign_key, :most_recent],
            unique: true,
            name: "index_#{transition_class.table_name}_parent_most_recent"
          )
        end
      end
    end
  end
end
