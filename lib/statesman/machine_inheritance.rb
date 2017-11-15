module Statesman
  module MachineInheritance
    def self.included(receiver)
      receiver.extend ClassMethods
    end

    module ClassMethods
      def inherit_from(state_machine)
        inherit_initial_state_from  state_machine
        inherit_states_from         state_machine
        inherit_transitions_from    state_machine
        inherit_callbacks_from      state_machine
      end

      def inherit_initial_state_from(state_machine)
        state state_machine.initial_state, initial: true
      end

      def inherit_states_from(state_machine)
        state_machine.states.each do |state_to_inherit|
          next if states.include? state_to_inherit
          state state_to_inherit
        end
      end

      def inherit_transitions_from(state_machine)
        state_machine.successors.each do |from, to|
          transition from: from, to: to
        end
      end

      def inherit_callbacks_from(state_machine)
        state_machine.callbacks.each do |callback_type, callbacks|
          callbacks.each do |callback|
            add_callback(
              callback_type: callback_type,
              callback_class: callback.class,
              from: callback.from,
              to: callback.to,
              &callback.callback
            )
          end
        end
      end
    end
  end
end
