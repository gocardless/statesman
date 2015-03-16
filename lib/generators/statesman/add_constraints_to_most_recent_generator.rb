require "rails/generators"
require "generators/statesman/generator_helpers"

module Statesman
  class AddConstraintsToMostRecentGenerator < Rails::Generators::Base
    include Statesman::GeneratorHelpers

    desc "Adds uniqueness and not-null constraints to the most recent column " \
         "for a statesman transition"

    argument :parent, type: :string, desc: "Your parent model name"
    argument :klass,  type: :string, desc: "Your transition model name"

    source_root File.expand_path('../templates', __FILE__)

    def create_model_file
      template("add_constraints_to_most_recent_migration.rb.erb",
               migration_file_name)
    end

    private

    def migration_file_name
      "db/migrate/#{next_migration_number}_"\
      "add_constraints_to_most_recent_for_#{table_name}.rb"
    end
  end
end
