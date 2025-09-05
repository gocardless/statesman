# frozen_string_literal: true

require "statesman"
require "sqlite3"
require "mysql2"
require "pg"
require "active_record"
require "active_record/database_configurations"
# We have to include all of Rails to make rspec-rails work
require "rails"
require "action_view"
require "action_dispatch"
require "action_controller"
require "rspec/rails"
require "support/exactly_query_databases"
require "rspec/its"
require "pry"
require "timecop"

RSpec.configure do |config|
  config.raise_errors_for_deprecations!
  config.mock_with(:rspec) { |mocks| mocks.verify_partial_doubles = true }

  config.order = "random"

  def connection_failure
    Moped::Errors::ConnectionFailure if defined?(Moped)
  end

  if config.exclusion_filter[:active_record]
    puts "Skipping ActiveRecord tests"
  else
    current_env = ActiveRecord::ConnectionHandling::DEFAULT_ENV.call

    # We have to parse this to a hash since ActiveRecord::Base.configurations
    # will only consider a single URL config.
    url_config = if ENV["DATABASE_URL"]
                   ActiveRecord::DatabaseConfigurations::ConnectionUrlResolver.
                     new(ENV["DATABASE_URL"]).to_hash.merge({ sslmode: "disable" })
                 end

    db_config = {
      current_env => {
        primary: url_config || {
          adapter: "sqlite3",
          database: "/tmp/statesman.db",
        },
        secondary: url_config || {
          adapter: "sqlite3",
          database: "/tmp/statesman.db",
        },
      },
    }

    # Connect to the primary database for activerecord tests.
    ActiveRecord::Base.configurations = db_config
    ActiveRecord::Base.establish_connection(:primary)

    db_adapter = ActiveRecord::Base.connection.adapter_name
    puts "Running with database adapter '#{db_adapter}'"

    # Silence migration output
    ActiveRecord::Migration.verbose = false
  end

  # Since our primary and secondary connections point to the same database, we don't
  # need to worry about applying these actions to both.
  config.before(:each, :active_record) do
    tables = %w[
      my_active_record_models
      my_active_record_model_transitions
      my_namespace_my_active_record_models
      my_namespace_my_active_record_model_transitions
      other_active_record_models
      other_active_record_model_transitions
      sti_active_record_models
      sti_active_record_model_transitions
    ]
    tables.each do |table_name|
      sql = "DROP TABLE IF EXISTS #{table_name};"

      ActiveRecord::Base.connection.execute(sql)
    end

    def prepare_model_table
      CreateMyActiveRecordModelMigration.migrate(:up)
    end

    def prepare_transitions_table
      CreateMyActiveRecordModelTransitionMigration.migrate(:up)
      MyActiveRecordModelTransition.reset_column_information
    end

    def prepare_other_model_table
      CreateOtherActiveRecordModelMigration.migrate(:up)
    end

    def prepare_other_transitions_table
      CreateOtherActiveRecordModelTransitionMigration.migrate(:up)
      OtherActiveRecordModelTransition.reset_column_information
    end

    def prepare_sti_model_table
      CreateStiActiveRecordModelMigration.migrate(:up)
    end

    def prepare_sti_transitions_table
      CreateStiActiveRecordModelTransitionMigration.migrate(:up)
      StiActiveRecordModelTransition.reset_column_information
    end
  end
end

# We have to require this after the databases are configured.
require "support/active_record"
