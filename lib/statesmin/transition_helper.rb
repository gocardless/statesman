module Statesmin
  module TransitionHelper
    # Methods to delegate to `state_machine`
    DELEGATED_METHODS = [:allowed_transitions, :can_transition_to?,
                         :current_state, :in_state?].freeze

    # Delegate the methods
    DELEGATED_METHODS.each do |method_name|
      module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def #{method_name}(*args)
          state_machine.#{method_name}(*args)
        end
      RUBY
    end

    def transition_to!(next_state, data = {})
      raise_transition_not_defined_error unless respond_to?(:transition)
      guard_transitions_to_invalid_states!(next_state)
      return_value = transition(next_state, data)
      @state_machine = nil
      return_value
    end

    def transition_to(next_state, data = {})
      transition_to!(next_state, data)
    rescue Statesmin::TransitionFailedError, Statesmin::GuardFailedError
      false
    end

    private

    def state_machine
      raise "'state_machine' method is not defined in '#{self.class.name}'." \
            "Either define this method or do not include 'TransitionHelper'."
    end

    def raise_transition_not_defined_error
      raise "'transition' method is not defined in '#{self.class.name}'." \
            "Either define this method or do not include 'TransitionHelper'."
    end

    def guard_transitions_to_invalid_states!(next_state)
      unless can_transition_to? next_state
        raise Statesmin::TransitionFailedError,
              "Cannot transition from '#{current_state}' to '#{next_state}'"
      end
    end
  end
end
