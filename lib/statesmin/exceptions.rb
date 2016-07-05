module Statesmin
  class InvalidStateError < StandardError; end
  class InvalidTransitionError < StandardError; end
  class InvalidCallbackError < StandardError; end
  class GuardFailedError < StandardError; end
  class TransitionFailedError < StandardError; end
  class TransitionConflictError < StandardError; end

  class NotImplementedError < StandardError
    def initialize(method_name, transition_class_name)
      super(_message(method_name, transition_class_name))
    end

    private

    def _message(method_name, transition_class_name)
      "'#{method_name}' method is not defined in '#{transition_class_name}'." \
      "Either define this method or do not include 'TransitionHelper'."
    end
  end
end
