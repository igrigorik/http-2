# frozen_string_literal: true

lib = File.expand_path("./lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "http/2/next/version"

Gem::Specification.new do |spec|
  spec.name          = "http-2-next"
  spec.version       = HTTP2Next::VERSION
  spec.authors       = ["Tiago Cardoso", "Ilya Grigorik", "Kaoru Maeda"]
  spec.email         = ["cardoso_tiago@hotmail.com"]
  spec.description   = "Pure-ruby HTTP 2.0 protocol implementation"
  spec.summary       = spec.description
  spec.homepage      = "https://gitlab.com/os85/http-2-next"
  spec.license       = "MIT"
  spec.required_ruby_version = ">=2.7.0"

  spec.metadata = {
    "bug_tracker_uri" => "https://gitlab.com/os85/http-2-next/issues",
    "changelog_uri" => "https://gitlab.com/os85/http-2-next/-/blob/master/CHANGELOG.md",
    "source_code_uri" => "https://gitlab.com/os85/http-2-next",
    "homepage_uri" => "https://gitlab.com/os85/http-2-next",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["LICENSE.txt", "README.md", "lib/**/*.rb", "sig/**/*.rbs"]
  spec.require_paths = ["lib"]
end
