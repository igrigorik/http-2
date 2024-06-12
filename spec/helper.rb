# frozen_string_literal: true

GC.auto_compact = true if GC.respond_to?(:auto_compact=)

if ENV.key?("CI")
  require "simplecov"
  SimpleCov.command_name "#{RUBY_ENGINE}-#{RUBY_VERSION}"
  SimpleCov.coverage_dir "coverage/#{RUBY_ENGINE}-#{RUBY_VERSION}"
end

RSpec.configure(&:disable_monkey_patching!)
RSpec::Expectations.configuration.warn_about_potential_false_positives = false

require "json"

# rubocop: disable Style/MixinUsage
require "http/2/next"
include HTTP2Next
include HTTP2Next::Header
include HTTP2Next::Error
# rubocop: enable Style/MixinUsage

REQUEST_HEADERS = [%w[:scheme https],
                   %w[:path /],
                   %w[:authority example.com],
                   %w[:method GET],
                   %w[a b]].freeze
RESPONSE_HEADERS = [%w[:status 200]].freeze

HTTP2Next::Connection.__send__ :public, :send_buffer
HTTP2Next::Stream.__send__ :public, :send_buffer

module FrameHelpers
  def data_frame
    {
      type: :data,
      flags: [:end_stream],
      stream: 1,
      payload: "text"
    }
  end

  def headers_frame
    {
      type: :headers,
      flags: [:end_headers].freeze,
      stream: 1,
      payload: Compressor.new.encode(REQUEST_HEADERS)
    }
  end

  def priority_frame
    {
      type: :priority,
      stream: 1,
      exclusive: false,
      dependency: 0,
      weight: 20
    }
  end

  def rst_stream_frame
    {
      type: :rst_stream,
      stream: 1,
      error: :stream_closed
    }
  end

  def settings_frame
    {
      type: :settings,
      stream: 0,
      payload: [
        [:settings_max_concurrent_streams, 10],
        [:settings_initial_window_size, 0x7fffffff]
      ]
    }
  end

  def push_promise_frame
    {
      type: :push_promise,
      flags: [:end_headers],
      stream: 1,
      promise_stream: 2,
      payload: Compressor.new.encode(REQUEST_HEADERS)
    }
  end

  def ping_frame
    {
      stream: 0,
      type: :ping,
      payload: "12345678"
    }
  end

  def pong_frame
    {
      stream: 0,
      type: :ping,
      flags: [:ack],
      payload: "12345678"
    }
  end

  def goaway_frame
    {
      type: :goaway,
      last_stream: 2,
      error: :no_error,
      payload: "debug"
    }
  end

  def window_update_frame
    {
      type: :window_update,
      increment: 10
    }
  end

  def continuation_frame
    {
      type: :continuation,
      flags: [:end_headers],
      payload: "-second-block"
    }
  end

  def altsvc_frame
    {
      type: :altsvc,
      max_age: 1_402_290_402,           # 4
      port: 8080,                       # 2    reserved 1
      proto: "h2-12",                   # 1 + 5
      host: "www.example.com",          # 1 + 15
      origin: "www.example.com"         # 15
    }
  end

  def origin_frame
    {
      type: :origin,
      payload: %w[https://www.example.com https://www.example.org]
    }
  end

  DATA_FRAMES = %w[headers continuation push_promise data].freeze

  def control_frames
    methods.select { |meth| meth.to_s.end_with?("_frame") }
           .reject { |meth| DATA_FRAMES.include?(meth.to_s.gsub(/_frame$/, "")) }
           .map { |meth| __send__(meth) }
  end

  def frame_types
    methods.select { |meth| meth.to_s.end_with?("_frame") }
           .map { |meth| __send__(meth) }
  end
end

def set_stream_id(bytes, id)
  scheme = "CnCCN"
  head = bytes.slice!(0, 9).unpack(scheme)
  head[4] = id

  head.pack(scheme) + bytes
end
