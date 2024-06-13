# frozen_string_literal: true

lib = File.expand_path("./lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "http/2/version"

Gem::Specification.new do |spec|
  spec.name          = "http-2"
  spec.version       = HTTP2::VERSION
  spec.authors       = ["Tiago Cardoso", "Ilya Grigorik", "Kaoru Maeda"]
  spec.email         = ["cardoso_tiago@hotmail.com"]
  spec.description   = "Pure-ruby HTTP 2.0 protocol implementation"
  spec.summary       = spec.description
  spec.homepage      = "https://github.com/igrigorik/http-2"
  spec.license       = "MIT"
  spec.required_ruby_version = ">=2.7.0"

  spec.metadata = {
    "bug_tracker_uri" => "https://github.com/igrigorik/http-2/issues",
    "changelog_uri" => "https://github.com/igrigorik/http-2/blob/main/CHANGELOG.md",
    "source_code_uri" => "https://github.com/igrigorik/http-2",
    "homepage_uri" => "https://github.com/igrigorik/http-2",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["LICENSE.txt", "README.md", "lib/**/*.rb", "sig/**/*.rbs"]
  spec.require_paths = ["lib"]
end
