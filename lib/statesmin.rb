module Statesmin
  autoload :Machine,    'statesmin/machine'
  autoload :Callback,   'statesmin/callback'
  autoload :Guard,      'statesmin/guard'
  autoload :Version,    'statesmin/version'
  require 'statesmin/railtie' if defined?(::Rails::Railtie)
end
