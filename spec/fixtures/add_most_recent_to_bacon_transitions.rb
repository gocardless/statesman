class AddMostRecentToBaconTransitions < ActiveRecord::Migration[4.2]
  def up
    add_column :bacon_transitions, :most_recent, :boolean, null: true
  end

  def down
    remove_column :bacon_transitions, :most_recent
  end
end
