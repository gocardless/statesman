module Statesman
  autoload :Config,     'statesman/config'
  autoload :Machine,    'statesman/machine'
  autoload :Callback,   'statesman/callback'
  autoload :Guard,      'statesman/guard'
  autoload :Version,    'statesman/version'
  require_relative "statesman/adapters/memory"
  require_relative "statesman/adapters/active_record"
  require_relative "statesman/adapters/active_record_transition"

  # Example:
  #   Statesman.configure do
  #     storage_adapter Statesman::ActiveRecordAdapter
  #   end
  #
  def self.configure(&block)
    config = Config.new(block)
    @storage_adapter = config.adapter_class
  end

  def self.storage_adapter
    @storage_adapter || Adapters::Memory
  end
end
