# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'statesmin/version'

Gem::Specification.new do |spec|
  spec.name          = "statesmin"
  spec.version       = Statesmin::VERSION
  spec.authors       = ["Chris Ewald"]
  spec.email         = ["chrisewald@gmail.com"]
  spec.description   = %q{A minimal statesmanlike state machine library}
  spec.summary       = spec.description
  spec.homepage      = "https://github.com/mkcode/statesmin"
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler",       "~> 1.3"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "rspec",         "~> 3.1"
  spec.add_development_dependency "rspec-its",     "~> 1.1"
  spec.add_development_dependency "rubocop",       "~> 0.30.0"
end
