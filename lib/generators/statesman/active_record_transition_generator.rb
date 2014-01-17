require "rails/generators"
require_relative "helpers/generator_helpers"

module Statesman
  class ActiveRecordTransitionGenerator < Rails::Generators::Base
    include GeneratorHelpers

    desc "Create an ActiveRecord-based transition model" +
         "with the required attributes"

    argument :parent, type: :string, desc: "Your parent model name"
    argument :klass, type: :string, desc: "Your transition model name"

    source_root File.expand_path('../templates', __FILE__)

    def create_model_file
      template("create_migration.rb.erb", migration_file_name)
      template("active_record_transition_model.rb.erb", model_file_name)
    end

    private

    def next_migration_number
      Time.now.utc.strftime("%Y%m%d%H%M%S")
    end

    def migration_file_name
      "db/migrate/#{next_migration_number}_create_#{table_name}.rb"
    end

    def model_file_name
      "app/models/#{klass.underscore}.rb"
    end

    def table_name
      klass.underscore.pluralize
    end

    def parent_id
      parent.underscore + "_id"
    end

    def rails_4?
      Rails.version.split(".").map(&:to_i).first >= 4
    end
  end
end
