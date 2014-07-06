module Statesman
  class EventTransitions
    attr_reader :machine, :event_name

    def initialize(machine, event_name, &block)
      @machine    = machine
      @event_name = event_name
      instance_eval(&block)
    end

    def transition(options = { from: nil, to: nil })
      machine.transition(options, event_name)
    end
  end
end
