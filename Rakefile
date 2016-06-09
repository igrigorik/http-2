require 'bundler/gem_tasks'
require 'rspec/core/rake_task'
require 'rubocop/rake_task'
require 'yard'
require_relative 'lib/tasks/generate_huffman_table'

RSpec::Core::RakeTask.new(:spec) do |t|
  t.exclude_pattern = './spec/hpack_test_spec.rb'
end

RSpec::Core::RakeTask.new(:hpack) do |t|
  t.pattern = './spec/hpack_test_spec.rb'
end

RuboCop::RakeTask.new
YARD::Rake::YardocTask.new

task default: [:spec, :rubocop]
task all: [:default, :hpack]
