require "rails/generators"
require "generators/statesman/generator_helpers"

module Statesman
  class AddMostRecentGenerator < Rails::Generators::Base
    include Statesman::GeneratorHelpers

    desc "Adds most_recent to a statesman transition model"

    argument :parent, type: :string, desc: "Your parent model name"
    argument :klass,  type: :string, desc: "Your transition model name"

    source_root File.expand_path('../templates', __FILE__)

    def create_model_file
      template("add_most_recent_migration.rb.erb", migration_file_name)
    end

    private

    def migration_file_name
      "db/migrate/#{next_migration_number}_add_most_recent_to_#{table_name}.rb"
    end
  end
end
