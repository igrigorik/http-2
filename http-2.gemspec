# frozen_string_literal: true

require_relative 'lib/http/2/version'

Gem::Specification.new do |spec|
  spec.name        = 'http-2'
  spec.version     = HTTP2::VERSION
  spec.authors     = ["Tiago Cardoso", "Ilya Grigorik", "Kaoru Maeda"]
  spec.email       = ['ilya@igvita.com', 'cardoso_tiago@hotmail.com']
  spec.description = 'Pure-ruby HTTP 2.0 protocol implementation'
  spec.summary     = spec.description
  spec.homepage    = 'https://github.com/igrigorik/http-2'
  spec.license     = 'MIT'
  spec.files       = Dir['LICENSE', 'README.md', 'lib/**/*.rb', 'sig/**/*.rbs']

  spec.add_runtime_dependency 'base64'

  spec.required_ruby_version = '>= 2.5'
end
