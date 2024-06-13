# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rake", require: false

group :development do
  gem "pry"
  gem "pry-byebug", platform: :mri
  if RUBY_VERSION >= "3.0.0"
    gem "rubocop"
    gem "rubocop-performance"
  end
end

group :docs do
  gem "yard"
end

group :test do
  gem "rspec"
  gem "simplecov", require: false
end

group :types do
  platform :mri do
    if RUBY_VERSION >= "3.0.0"
      gem "rbs"
      gem "steep"
      gem "typeprof"
    end
  end
end
