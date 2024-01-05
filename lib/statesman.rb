# frozen_string_literal: true

module Statesman
  autoload :Config,     "statesman/config"
  autoload :Machine,    "statesman/machine"
  autoload :Callback,   "statesman/callback"
  autoload :Guard,      "statesman/guard"
  autoload :Utils,      "statesman/utils"
  autoload :VERSION,    "statesman/version"
  module Adapters
    autoload :Memory,       "statesman/adapters/memory"
    autoload :ActiveRecord, "statesman/adapters/active_record"
    autoload :ActiveRecordTransition,
             "statesman/adapters/active_record_transition"
    autoload :ActiveRecordQueries,
             "statesman/adapters/active_record_queries"
    autoload :TypeSafeActiveRecordQueries,
             "statesman/adapters/type_safe_active_record_queries"
  end
  require "statesman/railtie" if defined?(::Rails::Railtie)

  # Example:
  #   Statesman.configure do
  #     storage_adapter Statesman::ActiveRecordAdapter
  #     enable_mysql_gaplock_protection
  #   end
  #
  def self.configure(&block)
    @config = Config.new(block)
    @storage_adapter = config.adapter_class
  end

  def self.storage_adapter
    @storage_adapter || Adapters::Memory
  end

  def self.mysql_gaplock_protection?(connection)
    config.mysql_gaplock_protection?(connection)
  end

  def self.config
    @config ||= Config.new
  end
end
