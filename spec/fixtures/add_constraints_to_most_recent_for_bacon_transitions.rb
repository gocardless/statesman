class AddConstraintsToMostRecentForBaconTransitions < ActiveRecord::Migration
  disable_ddl_transaction!

  def up
    add_index :bacon_transitions, [:bacon_id, :most_recent], unique: true, where: "most_recent", name: "index_bacon_transitions_parent_most_recent", algorithm: :concurrently
    change_column :bacon_transitions, :most_recent, :boolean, null: false
  end

  def down
    remove_index :bacon_transitions, name: "index_bacon_transitions_parent_most_recent"
    change_column :bacon_transitions, :most_recent, :boolean, null: true
  end
end
