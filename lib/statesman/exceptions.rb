module Statesman
  class InvalidStateError < StandardError; end
  class InvalidTransitionError < StandardError; end
  class GuardFailedError < StandardError; end
end
