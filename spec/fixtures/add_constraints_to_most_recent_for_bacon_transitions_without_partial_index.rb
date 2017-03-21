class AddConstraintsToMostRecentForBaconTransitions < ActiveRecord::Migration[4.2]
  disable_ddl_transaction!

  def up
    add_index :bacon_transitions, [:bacon_id, :most_recent], unique: true, name: "index_bacon_transitions_parent_most_recent", algorithm: :concurrently
  end

  def down
    remove_index :bacon_transitions, name: "index_bacon_transitions_parent_most_recent"
  end
end
