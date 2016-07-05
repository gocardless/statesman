module Statesman
  class InvalidStateError < StandardError; end
  class InvalidTransitionError < StandardError; end
  class InvalidCallbackError < StandardError; end
  class GuardFailedError < StandardError; end
  class TransitionFailedError < StandardError; end
  class TransitionConflictError < StandardError; end
end
