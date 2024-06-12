# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rake"
gem "simplecov", require: false
gem "yard"

gem "pry"
gem "pry-byebug", platform: :mri
gem "rspec", "~> 3.4.0"

if RUBY_VERSION >= "3.0"
  gem "rubocop"
  gem "rubocop-performance"
  platform :mri do
    gem "rbs"
    gem "steep"
    gem "typeprof"
  end
end

# gem "memory_profiler"
# gem "stackprof", platform: :mri
