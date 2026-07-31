# frozen_string_literal: true

SimpleCov.skip ".bundle/"
SimpleCov.skip "vendor/"
SimpleCov.skip "spec/"
SimpleCov.skip "lib/http/2/base64"
SimpleCov.command_name "#{RUBY_ENGINE}-#{RUBY_VERSION}"
SimpleCov.coverage_dir "coverage/#{RUBY_ENGINE}-#{RUBY_VERSION}"
