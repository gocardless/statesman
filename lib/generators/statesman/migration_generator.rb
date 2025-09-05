# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"
require "generators/statesman/generator_helpers"

# Add statesman attributes to a pre-existing transition class
module Statesman
  class MigrationGenerator < Rails::Generators::Base
    include Statesman::GeneratorHelpers
    include ActiveRecord::Generators::Migration

    desc "Add the required Statesman attributes to your transition model"

    argument :parent, type: :string, desc: "Your parent model name"
    argument :klass, type: :string, desc: "Your transition model name"

    source_root File.expand_path("templates", __dir__)

    def create_migration_file
      migration_template("update_migration.rb.erb", File.join(db_migrate_path, "add_statesman_to_#{table_name}.rb"))
    end
  end
end
