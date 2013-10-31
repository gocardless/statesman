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

  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "rspec", "~> 2.14.1"
  spec.add_development_dependency "guard-rspec", "~> 3.0.2"
  spec.add_development_dependency "rubocop", "~> 0.12.0"
  spec.add_development_dependency "guard-rubocop", "~> 0.2.2"
  spec.add_development_dependency "activerecord", "~> 3.2"
  spec.add_development_dependency "sqlite3", "~> 1.3.8"
  spec.add_development_dependency "mongoid", "~> 3.1.5"
end
