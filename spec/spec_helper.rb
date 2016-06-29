require "statesman"
# We have to include all of Rails to make rspec-rails work
require "rails"
require "action_view"
require "action_dispatch"
require "action_controller"
require "rspec/rails"
require "rspec/its"

RSpec.configure do |config|
  config.raise_errors_for_deprecations!
  config.mock_with(:rspec) { |mocks| mocks.verify_partial_doubles = true }

  config.order = "random"
end
