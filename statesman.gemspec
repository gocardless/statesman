# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'statesman/version'

Gem::Specification.new do |spec|
  spec.name          = "statesman"
  spec.version       = Statesman::VERSION
  spec.authors       = ["Harry Marr", "Andy Appleton"]
  spec.email         = ["developers@gocardless.com"]
  spec.description   = %q{A statesmanlike state machine library}
  spec.summary       = spec.description
  spec.homepage      = "https://github.com/gocardless/statesman"
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.required_ruby_version = '>= 2.2'
  spec.add_development_dependency "bundler",       "~> 1.3"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "rspec",         "~> 3.1"
  spec.add_development_dependency "rspec-rails",   "~> 3.1"
  spec.add_development_dependency "rspec-its",     "~> 1.1"
  spec.add_development_dependency "rubocop",       "~> 0.30.0"
  spec.add_development_dependency "sqlite3",       "~> 1.3"
  spec.add_development_dependency "rails",         ">= 3.2"
  spec.add_development_dependency "pg",            "~> 0.18"
  spec.add_development_dependency "mysql2",        "~> 0.4"
  spec.add_development_dependency "ammeter",       "~> 1.1"
end
