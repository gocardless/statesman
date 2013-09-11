module Statesman
  class Transition
    attr_accessor :created_at
    attr_accessor :from
    attr_accessor :to
    attr_accessor :metadata

    def initialize(from, to, metadata = nil)
      @created_at = Time.now
      @from = from
      @to = to
      @metadata = metadata
    end
  end
end
