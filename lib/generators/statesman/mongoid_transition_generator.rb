require "rails/generators"
require "generators/statesman/generator_helpers"

module Statesman
  class MongoidTransitionGenerator < Rails::Generators::Base
    include Statesman::GeneratorHelpers

    desc "Create a Mongoid-based transition model with the required attributes"

    argument :parent, type: :string, desc: "Your parent model name"
    argument :klass, type: :string, desc: "Your transition model name"

    source_root File.expand_path("../templates", __FILE__)

    def create_model_file
      template("mongoid_transition_model.rb.erb", model_file_name)
    end

    private

    def collection_name
      klass.underscore.pluralize
    end
  end
end
