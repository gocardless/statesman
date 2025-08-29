# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

if ENV['RAILS_VERSION'] == 'main'
  gem "rails", git: "https://github.com/rails/rails", branch: "main"
elsif ENV['RAILS_VERSION']
  gem "rails", "~> #{ENV['RAILS_VERSION']}"
else
  gem "rails", "~> 8.0"
end

group :development, :test do
  gem "ammeter", "~> 1.1"
  gem "bundler", "~> 2"
  gem "gc_ruboconfig", "~> 5.0.0"
  gem "mysql2", ">= 0.4", "< 0.6"
  gem "pg", ">= 0.18", "<= 1.7"
  gem "pry"
  gem "rake", "~> 13.2.1"
  gem "rspec", "~> 3.1"
  gem "rspec-github", "~> 3.0.0"
  gem "rspec-its", "~> 2.0"
  gem "rspec-rails", "~> 8.0"
  gem "sqlite3", "~> 2.5.0"
  gem "test-unit", "~> 3.3"
  gem "timecop", "~> 0.9.1"
end
