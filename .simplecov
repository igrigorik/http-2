# frozen_string_literal: true

SimpleCov.start do
  command_name "Spec"
  add_filter "/.bundle/"
  add_filter "/vendor/"
  add_filter "/spec/"
  add_filter "/lib/http/2/base64"
  coverage_dir "coverage"
  minimum_coverage(RUBY_ENGINE == "truffleruby" ? 85 : 90)
end
