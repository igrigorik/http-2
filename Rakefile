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

task :h2spec do
  system 'ruby example/server.rb -p 9000 &', out: File::NULL
  sleep 1

  system 'spec/h2spec/h2spec.darwin -p 9000'

  system 'kill `pgrep -f example/server.rb`'
end

RuboCop::RakeTask.new
YARD::Rake::YardocTask.new

task default: [:spec, :rubocop]
task all: [:default, :hpack]
