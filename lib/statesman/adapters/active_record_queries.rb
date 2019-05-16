module Statesman
  module Adapters
    module ActiveRecordQueries
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def in_state(*states)
          states = states.flatten.map(&:to_s)
          includes_initial = initial_state.to_s.in?(states)

          joins(most_recent_transition_join(includes_initial)).
            where(states_where(includes_initial), states)
        end

        def not_in_state(*states)
          states = states.flatten.map(&:to_s)
          includes_initial = initial_state.to_s.in?(states)

          joins(most_recent_transition_join(includes_initial)).
            where("NOT (#{states_where(includes_initial)})", states)
        end

        def most_recent_transition_join(includes_initial = true)
          if includes_initial
            "LEFT OUTER JOIN #{model_table} AS #{most_recent_transition_alias}
             ON #{table_name}.id = #{most_recent_transition_alias}.#{model_foreign_key}
             AND #{most_recent_transition_alias}.most_recent = #{db_true}"
          else
            "JOIN #{model_table} AS #{most_recent_transition_alias}
             ON #{table_name}.id = #{most_recent_transition_alias}.#{model_foreign_key}
             AND #{most_recent_transition_alias}.most_recent = #{db_true}"
          end
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
          @transition_reflection ||= reflect_on_all_associations(:has_many).
            find { |value| value.klass == transition_class }.
            tap do |value|
            if value.nil?
              raise MissingTransitionAssociation,
                    "Could not find has_many association between #{self.class} " \
                    "and #{transition_class}."
            end
          end
        end

        def model_foreign_key
          transition_reflection.foreign_key
        end

        def model_table
          transition_reflection.table_name
        end

        def states_where(includes_initial)
          if includes_initial
            "#{most_recent_transition_alias}.to_state IN (?) OR " \
            "#{most_recent_transition_alias}.to_state IS NULL"
          else
            "#{most_recent_transition_alias}.to_state IN (?)"
          end
        end

        def most_recent_transition_alias
          @most_recent_transition_alias ||=
            "most_recent_#{transition_name.to_s.singularize}"
        end

        def db_true
          ::ActiveRecord::Base.connection.quoted_true
        end
      end
    end
  end
end
