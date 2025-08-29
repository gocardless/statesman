# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "statesman/version"

GITHUB_URL = "https://github.com/gocardless/statesman"

Gem::Specification.new do |spec|
  spec.name          = "statesman"
  spec.version       = Statesman::VERSION
  spec.authors       = ["GoCardless"]
  spec.email         = ["developers@gocardless.com"]
  spec.description   = "A statesman-like state machine library"
  spec.summary       = spec.description
  spec.homepage      = GITHUB_URL
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($INPUT_RECORD_SEPARATOR)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "bug_tracker_uri" => "#{GITHUB_URL}/issues",
    "changelog_uri" => "#{GITHUB_URL}/blob/master/CHANGELOG.md",
    "documentation_uri" => "#{GITHUB_URL}/blob/master/README.md",
    "homepage_uri" => GITHUB_URL,
    "source_code_uri" => GITHUB_URL,
    "rubygems_mfa_required" => "true",
  }
end
