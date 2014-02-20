require "rails/generators"

module Statesman
  class MongoidTransitionGenerator < Rails::Generators::Base
    desc "Create a Mongoid-based transition model with the required attributes"

    argument :parent, type: :string, desc: "Your parent model name"
    argument :klass, type: :string, desc: "Your transition model name"

    source_root File.expand_path('../templates', __FILE__)

    def create_model_file
      template("mongoid_transition_model.rb.erb", model_file_name)
    end

    private

    def model_file_name
      "app/models/#{klass.underscore}.rb"
    end

    def collection_name
      klass.underscore.pluralize
    end

    def parent_id
      parent.underscore + "_id"
    end
  end
end
