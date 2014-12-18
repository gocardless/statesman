require "support/active_record"
require "json"

DB = Pathname.new("test.sqlite3")

class MyStateMachine
  include Statesman::Machine

  state :initial, initial: true
  state :succeeded
  state :failed

  transition from: :initial, to: [:succeeded, :failed]
  transition from: :failed,  to: :initial
end

class MyActiveRecordModel < ActiveRecord::Base
  has_many :my_active_record_model_transitions

  def state_machine
    @state_machine ||= MyStateMachine.new(
      self, transition_class: MyActiveRecordModelTransition)
  end

  def metadata
    super || {}
  end
end

class MyActiveRecordModelTransition < ActiveRecord::Base
  belongs_to :my_active_record_model
  serialize :metadata, JSON
end

class CreateMyActiveRecordModelMigration < ActiveRecord::Migration
  def change
    create_table :my_active_record_models do |t|
      t.string :current_state
      t.timestamps(null: false)
    end
  end
end

# TODO: make this a module we can extend from the app? Or a generator?
class CreateMyActiveRecordModelTransitionMigration < ActiveRecord::Migration
  def change
    create_table :my_active_record_model_transitions do |t|
      t.string  :to_state
      t.integer :my_active_record_model_id
      t.integer :sort_key
      t.text    :metadata, default: '{}'
      t.timestamps(null: false)
    end

    add_index :my_active_record_model_transitions, :sort_key, unique: true
  end
end
