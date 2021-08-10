# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

if ENV['RAILS_VERSION'] == 'main'
  gem "rails", git: "https://github.com/rails/rails", branch: "main"
elsif ENV['RAILS_VERSION']
  gem "rails", "~> #{ENV['RAILS_VERSION']}"
end
group :development do
  # test/unit is no longer bundled with Ruby 2.2, but required by Rails
  gem "test-unit", "~> 3.3" if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("2.2.0")
end
