require "statesman"
require "sqlite3"
require "active_record"
require "support/active_record"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.order = 'random'

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
