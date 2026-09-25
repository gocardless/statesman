# frozen_string_literal: true

module Statesman
  module GeneratorHelpers
    def class_name_option
      ", class_name: '#{parent}'" unless parent.underscore == parent_name
    end

    def model_file_name
      "app/models/#{klass.underscore}.rb"
    end

    def parent_name
      parent.underscore.split("/").join("_")
    end

    def parent_table_name
      parent.underscore.split("/").join("_").tableize
    end

    def parent_id
      parent_name + "_id"
    end

    def association_name
      klass.demodulize.underscore.pluralize
    end

    def table_name
      klass.underscore.split("/").join("_").tableize
    end

    def metadata_column_type
      if ActiveRecord::Base.connection.supports_json?
        postgres? ? :jsonb : :json
      else
        :text
      end
    end

    def index_name(index_id)
      "index_#{table_name}_#{index_id}"
    end

    def postgres?
      configuration.adapter.try(:match, /postgres/)
    end

    def mysql?
      configuration.adapter.try(:match, /mysql/)
    end

    def configuration
      ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).first
    end

    def database_supports_partial_indexes?
      Statesman::Adapters::ActiveRecord.database_supports_partial_indexes?(parent.constantize)
    end

    def metadata_column_config
      return if mysql?

      ", default: {}"
    end
  end
end
