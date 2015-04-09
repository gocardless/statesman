require "statesman"
require "sqlite3"
require "active_record"
require "support/active_record"
require "mongoid"
require "sequel"
require "rspec/its"

RSpec.configure do |config|
  config.raise_errors_for_deprecations!
  config.mock_with(:rspec) { |mocks| mocks.verify_partial_doubles = true }

  config.order = "random"

  # Try a mongo connection at the start of the suite and raise if it fails
  begin
    Mongoid.configure do |mongo_config|
      mongo_config.connect_to("statesman_test")
      mongo_config.sessions["default"]["options"]["max_retries"] = 2
    end
    # Attempting a mongo operation will trigger 2 retries then throw an
    # exception if mongo is not running.
    Mongoid.purge! unless config.exclusion_filter[:mongo]
  rescue Moped::Errors::ConnectionFailure => error
    puts "The spec suite requires MongoDB to be installed and running locally"
    puts "Mongo dependent specs can be filtered with rspec --tag '~mongo'"
    raise(error)
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
  end

  if config.exclusion_filter[:sequel]
    puts "Skipping Sequel tests"
  else
    Sequel::Model.db = Sequel.sqlite
    require "support/sequel"
  end

  config.before(:each, active_record: true) do
    tables = %w(
      my_active_record_models
      my_active_record_model_transitions
      my_namespace_my_active_record_models
      my_namespace_my_active_record_model_transitions
    )
    tables.each do |table_name|
      sql = "DROP TABLE IF EXISTS #{table_name};"
      ActiveRecord::Base.connection.execute(sql)
    end

    def prepare_model_table
      silence_stream(STDOUT) do
        CreateMyActiveRecordModelMigration.migrate(:up)
      end
    end

    def prepare_transitions_table
      silence_stream(STDOUT) do
        CreateMyActiveRecordModelTransitionMigration.migrate(:up)
        MyActiveRecordModelTransition.reset_column_information
      end
    end

    def drop_most_recent_column
      silence_stream(STDOUT) do
        DropMostRecentColumn.migrate(:up)
        MyActiveRecordModelTransition.reset_column_information
      end
    end
  end

  config.before(:each, sequel: true) do
    SequelMigrator.new(Sequel::Model.db).up
  end

  config.after(:each, sequel: true)  do
    SequelMigrator.new(Sequel::Model.db).down
  end
end
