# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

if ENV['RAILS_VERSION'] == 'main'
  gem "rails", git: "https://github.com/rails/rails", branch: "main"
elsif ENV['RAILS_VERSION']
  gem "rails", "~> #{ENV['RAILS_VERSION']}"
end

group :development do
  gem "pry"
  gem "test-unit", "~> 3.3"
end
