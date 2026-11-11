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
  gem "irb" if RUBY_VERSION >= "4.0.0"
end

group :test do
  gem "rspec"
end

if RUBY_VERSION >= "3.2.0"
  group :coverage do
    gem "repo-small-badge", require: false
    gem "simplecov", ">= 1.0.0", require: false
  end
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

group :benchmark do
  platform :mri do
    gem "memory_profiler"
    gem "singed"
  end
end
