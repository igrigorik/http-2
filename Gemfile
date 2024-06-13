# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

gem 'rake', require: false

group :development do
  gem 'pry'
  gem 'pry-byebug', platform: :mri
  gem 'rubocop'
  gem 'rubocop-performance'
end

group :docs do
  gem 'yard'
end

group :test do
  gem 'rspec'
  gem 'simplecov', require: false
end

group :types do
  gem 'rbs'
  gem 'steep'
  gem 'typeprof'
end
