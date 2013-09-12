require "support/active_record"

DB = Pathname.new("test.sqlite3")

class MyModel < ActiveRecord::Base
  has_many :my_model_transitions
end

class MyModelTransition < ActiveRecord::Base
  belongs_to :my_model
end

class CreateMyModelMigration < ActiveRecord::Migration
  def change
    create_table :my_models do |t|
      t.string :current_state
      t.timestamps
    end
  end
end

# TODO: make this a module we can extend from the app? Or a generator?
class CreateMyModelTransitionMigration < ActiveRecord::Migration
  def change
    create_table :my_model_transitions do |t|
      t.string  :to_state
      t.integer :my_model_id
      t.integer :order
      t.text    :metadata
      t.timestamps
    end
  end
end
