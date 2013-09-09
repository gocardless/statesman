module Statesman
  class Transition
    attr_accessor :created_at
    attr_accessor :from
    attr_accessor :to

    def initialize(from, to)
      @created_at = Time.now
      @from = from
      @to = to
    end
  end
end
