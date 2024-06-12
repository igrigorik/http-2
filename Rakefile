# frozen_string_literal: true

require "English"
require "bundler/gem_tasks"
require "open3"
require_relative "lib/tasks/generate_huffman_table"

RUBY_MAJOR_MINOR = RUBY_VERSION.split(".").first(2).join(".")

begin
  require "rspec/core/rake_task"
  RSpec::Core::RakeTask.new(:spec) do |t|
    t.exclude_pattern = "./spec/hpack_test_spec.rb"
  end

  RSpec::Core::RakeTask.new(:hpack) do |t|
    t.pattern = "./spec/hpack_test_spec.rb"
  end
rescue LoadError
end

begin
  require "rubocop/rake_task"
  desc "Run rubocop"
  RuboCop::RakeTask.new
rescue LoadError
end

begin
  require "yard"
  YARD::Rake::YardocTask.new
rescue LoadError
end

namespace :coverage do
  desc "Aggregates coverage reports"
  task :report do
    return unless ENV.key?("CI")

    require "simplecov"

    SimpleCov.collate Dir["coverage/**/.resultset.json"]
  end
end

desc "install h2spec"
task :h2spec_install do
  platform = case RUBY_PLATFORM
             when /darwin/
               "h2spec_darwin_amd64.tar.gz"
             when /cygwin|mswin|mingw|bccwin|wince|emx/
               "h2spec_windows_amd64.zip"
             else
               "h2spec_linux_amd64.tar.gz"
             end
  # uri = "https://github.com/summerwind/h2spec/releases/download/v2.3.0/#{platform}"

  tar_location = File.join(__dir__, "h2spec-releases", platform)
  # require "net/http"
  # File.open(tar_location, "wb") do |file|
  #   response = nil
  #   loop do
  #     uri = URI(uri)
  #     http = Net::HTTP.new(uri.host, uri.port)
  #     http.use_ssl = true
  #     # http.set_debug_output($stderr)
  #     response = http.get(uri.request_uri)
  #     break unless response.is_a?(Net::HTTPRedirection)

  #     uri = response["location"]
  #   end
  #   file.write(response.body)
  # end

  case RUBY_PLATFORM
  when /cygwin|mswin|mingw|bccwin|wince|emx/
    puts "Hi, you're on Windows, please unzip this file: #{tar_location}"
  when /darwin/
    system("gunzip -c #{tar_location} | tar -xvzf -")
  else
    system("tar -xvzf #{tar_location} h2spec")
  end
  # FileUtils.rm(tar_location)
end

desc "run h2spec"
task :h2spec do
  h2spec = File.join(__dir__, "h2spec")
  unless File.exist?(h2spec)
    abort 'Please install h2spec first.\n' \
          'Run "rake h2spec_install",\n' \
          "Or Download the binary from https://github.com/summerwind/h2spec/releases"
  end

  server_pid = Process.spawn("ruby example/server.rb -p 9000", out: File::NULL)
  sleep RUBY_ENGINE == "ruby" ? 5 : 20
  system("#{h2spec} -p 9000 -o 2 --strict")
  Process.kill("TERM", server_pid)
  exit($CHILD_STATUS.exitstatus)
end

default_tasks = %i[spec]
default_tasks << :rubocop if defined?(RuboCop) && RUBY_ENGINE == "ruby"
default_tasks += %i[h2spec_install h2spec] if ENV.key?("CI") && RUBY_VERSION >= "3.0.0"
task default: default_tasks
task all: %i[default hpack]
