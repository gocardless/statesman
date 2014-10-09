module Statesman
  module Adapters
    module ActiveRecordModel
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def in_state(*states)
          states = states.map(&:to_s)

          joins(transition1_join)
            .joins(transition2_join)
            .where(state_inclusion_where(states), states)
            .where("transition2.id" => nil)
        end

        def not_in_state(*states)
          states = states.map(&:to_s)

          joins(transition1_join)
            .joins(transition2_join)
            .where("NOT (#{state_inclusion_where(states)})", states)
            .where("transition2.id" => nil)
        end

        private

        def transition_class
          raise NotImplementedError, "A transition_class method should be " +
                                     "defined on the model"
        end

        def initial_state
          raise NotImplementedError, "An initial_state method should be " \
                                     "defined on the model"
        end

        def transition_name
          transition_class.table_name.to_sym
        end

        def model_foreign_key
          reflections[transition_name].foreign_key
        end

        def transition1_join
          "LEFT OUTER JOIN #{transition_name} transition1
             ON transition1.#{model_foreign_key} = #{table_name}.id"
        end

        def transition2_join
          "LEFT OUTER JOIN #{transition_name} transition2
             ON transition2.#{model_foreign_key} = #{table_name}.id
             AND transition2.sort_key > transition1.sort_key"
        end

        def state_inclusion_where(states)
          if initial_state.in?(states)
            'transition1.to_state IN (?) OR ' \
            'transition1.to_state IS NULL'
          else
            'transition1.to_state IN (?) AND ' \
            'transition1.to_state IS NOT NULL'
          end
        end
      end
    end
  end
end
