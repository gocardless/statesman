require "json"

MIGRATION_CLASS = if Rails.version.split(".").map(&:to_i).first >= 5
                    migration_version = ActiveRecord::Migration.current_version
                    ActiveRecord::Migration[migration_version]
                  else
                    ActiveRecord::Migration
                  end

class MyStateMachine
  include Statesman::Machine

  state :initial, initial: true
  state :succeeded
  state :failed

  transition from: :initial, to: %i[succeeded failed]
  transition from: :failed,  to: :initial
end

class MyActiveRecordModel < ActiveRecord::Base
  has_many :my_active_record_model_transitions, autosave: false
  alias_method :transitions, :my_active_record_model_transitions

  def state_machine
    @state_machine ||= MyStateMachine.new(
      self, transition_class: MyActiveRecordModelTransition
    )
  end

  def metadata
    super || {}
  end
end

class MyActiveRecordModelTransition < ActiveRecord::Base
  include Statesman::Adapters::ActiveRecordTransition

  belongs_to :my_active_record_model
  serialize :metadata, JSON
end

class MyActiveRecordModelTransitionWithoutInclude < ActiveRecord::Base
  self.table_name = "my_active_record_model_transitions"

  belongs_to :my_active_record_model
  serialize :metadata, JSON
end

class CreateMyActiveRecordModelMigration < MIGRATION_CLASS
  def change
    create_table :my_active_record_models do |t|
      t.string :current_state
      t.timestamps null: false
    end
  end
end

# TODO: make this a module we can extend from the app? Or a generator?
# rubocop:disable MethodLength, Metrics/AbcSize
class CreateMyActiveRecordModelTransitionMigration < MIGRATION_CLASS
  def change
    create_table :my_active_record_model_transitions do |t|
      t.string  :to_state
      t.integer :my_active_record_model_id
      t.integer :sort_key

      # MySQL doesn't allow default values on text fields
      if ActiveRecord::Base.connection.adapter_name == "Mysql2"
        t.text :metadata
      else
        t.text :metadata, default: "{}"
      end

      if Statesman::Adapters::ActiveRecord.database_supports_partial_indexes?
        t.boolean :most_recent, default: true, null: false
      else
        t.boolean :most_recent, default: true
      end

      t.timestamps null: false

      # We'll use this to test customising the updated_timestamp_column setting on the
      # transition class.
      t.date :updated_on
    end

    add_index :my_active_record_model_transitions,
              %i[my_active_record_model_id sort_key],
              unique: true, name: "sort_key_index"

    if Statesman::Adapters::ActiveRecord.database_supports_partial_indexes?
      add_index :my_active_record_model_transitions,
                %i[my_active_record_model_id most_recent],
                unique: true,
                where: "most_recent",
                name: "index_my_active_record_model_transitions_parent_latest"
    else
      add_index :my_active_record_model_transitions,
                %i[my_active_record_model_id most_recent],
                unique: true,
                name: "index_my_active_record_model_transitions_parent_latest"
    end
  end
end
# rubocop:enable MethodLength, Metrics/AbcSize

class OtherActiveRecordModel < ActiveRecord::Base
  has_many :other_active_record_model_transitions, autosave: false
  alias_method :transitions, :other_active_record_model_transitions

  def state_machine
    @state_machine ||= MyStateMachine.new(
      self, transition_class: OtherActiveRecordModelTransition
    )
  end

  def metadata
    super || {}
  end
end

class OtherActiveRecordModelTransition < ActiveRecord::Base
  include Statesman::Adapters::ActiveRecordTransition

  belongs_to :other_active_record_model
  serialize :metadata, JSON
end

class CreateOtherActiveRecordModelMigration < MIGRATION_CLASS
  def change
    create_table :other_active_record_models do |t|
      t.string :current_state
      t.integer :my_active_record_model_id
      t.timestamps null: false
    end
  end
end

# rubocop:disable MethodLength
class CreateOtherActiveRecordModelTransitionMigration < MIGRATION_CLASS
  def change
    create_table :other_active_record_model_transitions do |t|
      t.string  :to_state
      t.integer :other_active_record_model_id
      t.integer :sort_key

      # MySQL doesn't allow default values on text fields
      if ActiveRecord::Base.connection.adapter_name == "Mysql2"
        t.text :metadata
      else
        t.text :metadata, default: "{}"
      end

      if Statesman::Adapters::ActiveRecord.database_supports_partial_indexes?
        t.boolean :most_recent, default: true, null: false
      else
        t.boolean :most_recent, default: true
      end

      t.timestamps null: false
    end

    add_index :other_active_record_model_transitions,
              %i[other_active_record_model_id sort_key],
              unique: true, name: "other_sort_key_index"

    if Statesman::Adapters::ActiveRecord.database_supports_partial_indexes?
      add_index :other_active_record_model_transitions,
                %i[other_active_record_model_id most_recent],
                unique: true,
                where: "most_recent",
                name: "index_other_active_record_model_transitions_"\
                      "parent_latest"
    else
      add_index :other_active_record_model_transitions,
                %i[other_active_record_model_id most_recent],
                unique: true,
                name: "index_other_active_record_model_transitions_"\
                      "parent_latest"
    end
  end
end
# rubocop:enable MethodLength

class DropMostRecentColumn < MIGRATION_CLASS
  def change
    remove_index :my_active_record_model_transitions,
                 name: "index_my_active_record_model_transitions_parent_latest"
    remove_column :my_active_record_model_transitions, :most_recent
  end
end

module MyNamespace
  class MyActiveRecordModel < ActiveRecord::Base
    has_many :my_active_record_model_transitions,
             class_name: "MyNamespace::MyActiveRecordModelTransition",
             autosave: false

    def self.table_name_prefix
      "my_namespace_"
    end

    def state_machine
      @state_machine ||= MyStateMachine.new(
        self, transition_class: MyNamespace::MyActiveRecordModelTransition,
              association_name: :my_active_record_model_transitions
      )
    end

    def metadata
      super || {}
    end
  end

  class MyActiveRecordModelTransition < ActiveRecord::Base
    include Statesman::Adapters::ActiveRecordTransition

    belongs_to :my_active_record_model,
               class_name: "MyNamespace::MyActiveRecordModel"
    serialize :metadata, JSON

    def self.table_name_prefix
      "my_namespace_"
    end
  end
end

class CreateNamespacedARModelMigration < MIGRATION_CLASS
  def change
    create_table :my_namespace_my_active_record_models do |t|
      t.string :current_state
      t.timestamps null: false
    end
  end
end

# rubocop:disable MethodLength
class CreateNamespacedARModelTransitionMigration < MIGRATION_CLASS
  def change
    create_table :my_namespace_my_active_record_model_transitions do |t|
      t.string  :to_state
      t.integer :my_active_record_model_id
      t.integer :sort_key

      # MySQL doesn't allow default values on text fields
      if ActiveRecord::Base.connection.adapter_name == "Mysql2"
        t.text :metadata
      else
        t.text :metadata, default: "{}"
      end

      if Statesman::Adapters::ActiveRecord.database_supports_partial_indexes?
        t.boolean :most_recent, default: true, null: false
      else
        t.boolean :most_recent, default: true
      end

      t.timestamps null: false
    end

    add_index :my_namespace_my_active_record_model_transitions, :sort_key,
              unique: true, name: "my_namespaced_key"

    if Statesman::Adapters::ActiveRecord.database_supports_partial_indexes?
      add_index :my_namespace_my_active_record_model_transitions,
                %i[my_active_record_model_id most_recent],
                unique: true,
                where: "most_recent",
                name: "index_namespace_model_transitions_parent_latest"
    else
      add_index :my_namespace_my_active_record_model_transitions,
                %i[my_active_record_model_id most_recent],
                unique: true,
                name: "index_namespace_model_transitions_parent_latest"
    end
  end
  # rubocop:enable MethodLength
end
