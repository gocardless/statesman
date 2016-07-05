module Statesman
  autoload :Machine,    'statesman/machine'
  autoload :Callback,   'statesman/callback'
  autoload :Guard,      'statesman/guard'
  autoload :Version,    'statesman/version'
  require 'statesman/railtie' if defined?(::Rails::Railtie)
end
