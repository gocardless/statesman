module Statesman
  module GeneratorHelpers
    def class_name_option
      ", class_name: '#{parent}'" unless parent.underscore == parent_name
    end

    def model_file_name
      "app/models/#{klass.underscore}.rb"
    end

    def migration_class_name
      klass.gsub(/::/, "").pluralize
    end

    def next_migration_number
      Time.now.utc.strftime("%Y%m%d%H%M%S")
    end

    def parent_name
      parent.demodulize.underscore
    end

    def parent_table_name
      parent.demodulize.underscore.pluralize
    end

    def parent_id
      parent_name + "_id"
    end

    def table_name
      klass.demodulize.underscore.pluralize
    end

    def index_name(index_id)
      "index_#{table_name}_#{index_id}"
    end

    def mysql?
      ActiveRecord::Base.configurations[Rails.env].
        try(:[], "adapter").try(:match, /mysql/)
    end

    def database_supports_partial_indexes?
      Statesman::Adapters::ActiveRecord.database_supports_partial_indexes?
    end

    def metadata_default_value
      Utils.rails_5_or_higher? ? "{}" : "{}".inspect
    end
  end
end
