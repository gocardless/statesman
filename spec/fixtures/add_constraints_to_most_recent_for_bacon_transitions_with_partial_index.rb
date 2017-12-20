class AddConstraintsToMostRecentForBaconTransitions < ActiveRecord::Migration
  disable_ddl_transaction!

  def up
    add_index :bacon_transitions,
              %i[bacon_id most_recent],
              unique: true,
              where: "most_recent",
              name: "index_bacon_transitions_parent_most_recent",
              algorithm: :concurrently
    change_column_null :bacon_transitions, :most_recent, false
  end

  def down
    remove_index :bacon_transitions, name: "index_bacon_transitions_parent_most_recent"
    change_column_null :bacon_transitions, :most_recent, true
  end
end
