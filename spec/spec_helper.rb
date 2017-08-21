require "statesman"
require "sqlite3"
require "mysql2"
require "pg"
require "active_record"
# We have to include all of Rails to make rspec-rails work
require "rails"
require "action_view"
require "action_dispatch"
require "action_controller"
require "rspec/rails"
require "support/active_record"
require "rspec/its"

RSpec.configure do |config|
  config.raise_errors_for_deprecations!
  config.mock_with(:rspec) { |mocks| mocks.verify_partial_doubles = true }

  config.order = "random"

  def connection_failure
    if defined?(Moped)
      Moped::Errors::ConnectionFailure
    else
      Mongo::Error::NoServerAvailable
    end
  end

  if config.exclusion_filter[:mongo]
    puts "Skipping Mongo tests"
  else
    require "mongoid"

    # Try a mongo connection at the start of the suite and raise if it fails
    begin
      Mongoid.configure do |mongo_config|
        if defined?(Moped)
          mongo_config.connect_to("statesman_test")
          mongo_config.sessions["default"]["options"]["max_retries"] = 2
        else
          mongo_config.connect_to("statesman_test", server_selection_timeout: 2)
        end
      end
      # Attempting a mongo operation will trigger 2 retries then throw an
      # exception if mongo is not running.
      Mongoid.purge!
    rescue connection_failure => error
      puts "The spec suite requires MongoDB to be installed and running locally"
      puts "Mongo dependent specs can be filtered with rspec --tag '~mongo'"
      raise(error)
    end
  end

  if config.exclusion_filter[:active_record]
    puts "Skipping ActiveRecord tests"
  else
    # Connect to the database for activerecord tests
    db_conn_spec = ENV["DATABASE_URL"]
    db_conn_spec ||= { adapter: "sqlite3", database: ":memory:" }
    ActiveRecord::Base.establish_connection(db_conn_spec)

    db_adapter = ActiveRecord::Base.connection.adapter_name
    puts "Running with database adapter '#{db_adapter}'"

    # Silence migration output
    ActiveRecord::Migration.verbose = false
  end

  config.before(:each, active_record: true) do
    tables = %w[
      my_active_record_models
      my_active_record_model_transitions
      my_namespace_my_active_record_models
      my_namespace_my_active_record_model_transitions
      other_active_record_models
      other_active_record_model_transitions
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

    MyNamespace::MyActiveRecordModelTransition.serialize(:metadata, JSON)
  end
end
