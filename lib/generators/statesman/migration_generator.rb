require "rails/generators"
require_relative "helpers/generator_helpers"

# Add statesman attributes to a pre-existing transition class
module Statesman
  class MigrationGenerator < Rails::Generators::Base
    include GeneratorHelpers

    desc "Add the required Statesman attributes to your transition model"

    argument :parent, type: :string, desc: "Your parent model name"
    argument :klass, type: :string, desc: "Your transition model name"

    source_root File.expand_path('../templates', __FILE__)

    def create_model_file
      template("update_migration.rb.erb", file_name)
    end

    private

    def next_migration_number
      Time.now.utc.strftime("%Y%m%d%H%M%S")
    end

    def file_name
      "db/migrate/#{next_migration_number}_add_statesman_to_#{table_name}.rb"
    end

    def table_name
      klass.underscore.pluralize
    end

    def parent_id
      parent.underscore + "_id"
    end
  end
end
