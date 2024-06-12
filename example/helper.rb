# frozen_string_literal: true

$LOAD_PATH << "lib" << "../lib"

require "optparse"
require "socket"
require "openssl"
require "uri"

# This will enable coverage within the CI environment
if ENV.key?("CI")
  require "simplecov"
  SimpleCov.command_name "#{RUBY_ENGINE}-#{RUBY_VERSION}-h2spec"
  SimpleCov.coverage_dir "coverage/#{RUBY_ENGINE}-#{RUBY_VERSION}-h2spec"
end

require "http/2/next"

DRAFT = "h2"

class Logger
  def initialize(id)
    @id = id
  end

  def info(msg)
    puts "[Stream #{@id}]: #{msg}"
  end
end
