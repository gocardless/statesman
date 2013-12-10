require "statesman"
require "sqlite3"
require "active_record"
require "support/active_record"
require "mongoid"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.order = "random"

  # Try a mongo connection at the start of the suite and raise if it fails
  begin
    Mongoid.configure do |config|
      config.connect_to("statesman_test")
      config.sessions["default"]["options"]["max_retries"] = 2
    end
    # Attempting a mongo operation will triger 2 retries then trow an exception
    # if mongo is not running.
    Mongoid.purge! unless config.exclusion_filter[:mongo]
  rescue Moped::Errors::ConnectionFailure => error
    puts "The spec suite requires MongoDB to be installed and running locally"
    puts "Mongo dependent specs can be filtered with rspec --tag '~mongo'"
    raise(error)
  end

  config.before(:each) do
    # Connect to & cleanup test database
    ActiveRecord::Base.establish_connection(adapter: "sqlite3",
                                            database: DB.to_s)

    %w(my_models my_model_transitions).each do |table_name|
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
      end
    end
  end

  config.after(:each) { DB.delete if DB.exist? }
end
