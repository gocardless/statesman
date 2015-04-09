require "sequel"

class SequelMigrator
  MODEL_TABLE = "my_sequel_models"
  TRANSITION_TABLE = "my_sequel_model_transitions"

  def initialize(db)
    @db = db
  end

  def up
    down
    create_model_table
    create_transition_table
  end

  def down
    [TRANSITION_TABLE, MODEL_TABLE].each do |table_name|
      @db.execute("DROP TABLE IF EXISTS #{table_name};")
    end
  end

  private

  def create_model_table
    @db.create_table(:my_sequel_models) do
      primary_key :id, type: Bignum
      String :current_state
    end
  end

  def create_transition_table
    @db.create_table(:my_sequel_model_transitions) do
      primary_key :id, type: Bignum
      String :to_state
      foreign_key :my_sequel_model_id, :my_sequel_models
      Bignum :sort_key, index: true, unique: true
      String :metadata
    end
  end
end
