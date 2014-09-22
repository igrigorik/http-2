require "bundler/gem_tasks"
require "rspec/core/rake_task"
require_relative "lib/tasks/generate_huffman_table"

desc "Run all RSpec tests"
RSpec::Core::RakeTask.new(:spec)

task :default => :spec
task :test => [:spec]

require 'yard'
YARD::Rake::YardocTask.new
