# frozen_string_literal: true

$LOAD_PATH << "lib" << "../lib"

require "optparse"
require "socket"
require "openssl"
require "uri"

# This will enable coverage within the CI environment
if ENV.key?("CI") && RUBY_VERSION >= "3.2.0"
  require "simplecov"
  SimpleCov.start do
    coverage_dir ENV.fetch("COVERAGE_DIR") { "coverage/#{RUBY_ENGINE}-#{RUBY_VERSION}-h2spec" }
    merging true
    finalize_merge false
  end
end

require "http/2"

DRAFT = "h2"

class Logger
  def initialize(id)
    @id = id
  end

  def info(msg)
    puts "[Stream #{@id}]: #{msg}"
  end
end
