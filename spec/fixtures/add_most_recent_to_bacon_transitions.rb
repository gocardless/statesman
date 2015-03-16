class AddMostRecentToBaconTransitions < ActiveRecord::Migration
  def up
    add_column :bacon_transitions, :most_recent, :boolean, null: true
  end

  def down
    drop_column :bacon_transitions, :most_recent
  end
end
