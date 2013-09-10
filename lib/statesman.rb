module Statesman
  autoload :Config,     'statesman/config'
  autoload :Machine,    'statesman/machine'
  autoload :Callback,   'statesman/callback'
  autoload :Guard,      'statesman/guard'
  autoload :Transition, 'statesman/transition'
  autoload :Version,    'statesman/version'
  require "statesman/adapters/memory"
  require "statesman/adapters/active_record"

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
