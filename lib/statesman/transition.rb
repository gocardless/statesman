module Statesman
  class Transition
    attr_accessor :created_at
    attr_accessor :to_state
    attr_accessor :metadata

    def initialize(to, metadata = nil)
      @created_at = Time.now
      @to_state = to
      @metadata = metadata
    end
  end
end
