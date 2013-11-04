require "support/active_record"

DB = Pathname.new("test.sqlite3")

class MyActiveRecordModel < ActiveRecord::Base
  has_many :my_active_record_model_transitions
end

class MyActiveRecordModelTransition < ActiveRecord::Base
  belongs_to :my_active_record_model
end

class CreateMyActiveRecordModelMigration < ActiveRecord::Migration
  def change
    create_table :my_active_record_models do |t|
      t.string :current_state
      t.timestamps
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
      t.text    :metadata
      t.timestamps
    end

    add_index :my_active_record_model_transitions, :sort_key, unique: true
  end
end
