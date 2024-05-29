require_relative 'lib/http/2/version'

Gem::Specification.new do |spec|
  spec.name          = 'http-2'
  spec.version       = HTTP2::VERSION
  spec.authors       = ['Ilya Grigorik', 'Kaoru Maeda']
  spec.email         = ['ilya@igvita.com']
  spec.description   = 'Pure-ruby HTTP 2.0 protocol implementation'
  spec.summary       = spec.description
  spec.homepage      = 'https://github.com/igrigorik/http-2'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>=2.1.0'

  spec.files         = Dir["LICENSE", "README.md", "lib/**/*.rb"]
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  spec.add_development_dependency 'bundler'
end
