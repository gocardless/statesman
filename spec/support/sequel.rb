require "json"
require "sequel"
require_relative "./sequel_migrations"

class SequelStateMachine
  include Statesman::Machine

  state :initial, initial: true
  state :succeeded
  state :failed

  transition from: :initial, to: [:succeeded, :failed]
  transition from: :failed,  to: :initial
end

class MySequelModel < Sequel::Model
  one_to_many :my_sequel_model_transitions

  def state_machine
    @state_machine ||= SequelStateMachine.new(
      self, transition_class: MySequelModelTransition)
  end

  def metadata
    super || {}
  end
end

class MySequelModelTransition < Sequel::Model
  many_to_one :my_sequel_model
  # TODO
  # serialize :metadata, JSON
end
