lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "statesman/version"

Gem::Specification.new do |spec|
  spec.name          = "statesman"
  spec.version       = Statesman::VERSION
  spec.authors       = ["GoCardless"]
  spec.email         = ["developers@gocardless.com"]
  spec.description   = "A statesman-like state machine library"
  spec.summary       = spec.description
  spec.homepage      = "https://github.com/gocardless/statesman"
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($INPUT_RECORD_SEPARATOR)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 2.2"

  spec.add_development_dependency "ammeter", "~> 1.1"
  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "gc_ruboconfig", "~> 2.3.9"
  spec.add_development_dependency "mysql2", ">= 0.4", "< 0.6"
  spec.add_development_dependency "pg", "~> 0.18"
  spec.add_development_dependency "pry"
  spec.add_development_dependency "rails", ">= 3.2"
  spec.add_development_dependency "rake", "~> 13.0.0"
  spec.add_development_dependency "rspec", "~> 3.1"
  spec.add_development_dependency "rspec-its", "~> 1.1"
  spec.add_development_dependency "rspec-rails", "~> 3.1"
  spec.add_development_dependency "rspec_junit_formatter", "~> 0.4.0"
  spec.add_development_dependency "sqlite3", "~> 1.3.6"
  spec.add_development_dependency "timecop", "~> 0.9.1"
end
