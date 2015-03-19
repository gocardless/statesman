source 'https://rubygems.org'

gemspec

gem "rails", "~> #{ENV["RAILS_VERSION"]}" if ENV["RAILS_VERSION"]

# test/unit is no longer bundled with Ruby 2.2, but required by Rails
if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("2.2.0")
  gem "test-unit", "~> 3.0"
end
