module Statesmin
  autoload :Callback,         'statesmin/callback'
  autoload :Guard,            'statesmin/guard'
  autoload :Machine,          'statesmin/machine'
  autoload :TransitionHelper, 'statesmin/transition_helper'
  autoload :Version,          'statesmin/version'
  require 'statesmin/railtie' if defined?(::Rails::Railtie)
end
