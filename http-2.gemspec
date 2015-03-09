# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'http/2/version'

Gem::Specification.new do |spec|
  spec.name          = 'http-2'
  spec.version       = HTTP2::VERSION
  spec.authors       = ['Ilya Grigorik', 'Kaoru Maeda']
  spec.email         = ['ilya@igvita.com']
  spec.description   = 'Pure-ruby HTTP 2.0 protocol implementation'
  spec.summary       = spec.description
  spec.homepage      = 'https://github.com/igrigorik/http-2'
  spec.license       = 'MIT'

  spec.files         = `git ls-files`.split($INPUT_RECORD_SEPARATOR)
  spec.executables   = spec.files.grep(/^bin\//) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(/^(test|spec|features)\//)
  spec.require_paths = ['lib']

  spec.add_development_dependency 'bundler', '~> 1.3'
end
