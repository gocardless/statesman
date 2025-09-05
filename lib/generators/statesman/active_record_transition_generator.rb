# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"
require "generators/statesman/generator_helpers"

module Statesman
  class ActiveRecordTransitionGenerator < Rails::Generators::Base
    include Statesman::GeneratorHelpers
    include ActiveRecord::Generators::Migration

    desc "Create an ActiveRecord-based transition model" \
         "with the required attributes"

    argument :parent, type: :string, desc: "Your parent model name"
    argument :klass,  type: :string, desc: "Your transition model name"

    source_root File.expand_path("templates", __dir__)

    def create_model_file
      template("active_record_transition_model.rb.erb", model_file_name)
    end

    def create_migration_file
      migration_template("create_migration.rb.erb", File.join(db_migrate_path, "create_#{table_name}.rb"))
    end
  end
end
