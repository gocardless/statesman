require "rails/generators"
require "generators/statesman/generator_helpers"

module Statesman
  class ActiveRecordTransitionGenerator < Rails::Generators::Base
    include Statesman::GeneratorHelpers

    desc "Create an ActiveRecord-based transition model"\
         "with the required attributes"

    argument :parent, type: :string, desc: "Your parent model name"
    argument :klass,  type: :string, desc: "Your transition model name"

    source_root File.expand_path('../templates', __FILE__)

    def create_model_file
      template("create_migration.rb.erb", migration_file_name)
      template("active_record_transition_model.rb.erb", model_file_name)
    end

    private

    def migration_file_name
      "db/migrate/#{next_migration_number}_create_#{table_name}.rb"
    end

    def under_rails_4?
      Rails::VERSION::MAJOR < 4
    end

    def under_rails_5?
      Rails::VERSION::MAJOR < 5
    end
  end
end
