RSpec.configure(&:disable_monkey_patching!)

require 'json'
require 'coveralls'

Coveralls.wear! if ENV['CI']

require 'http/2'

include HTTP2
include HTTP2::Header
include HTTP2::Error

DATA = {
  type: :data,
  flags: [:end_stream],
  stream: 1,
  payload: 'text',
}

HEADERS = {
  type: :headers,
  flags: [:end_headers],
  stream: 1,
  payload: Compressor.new.encode([%w(a b)]),
}

HEADERS_END_STREAM = {
  type: :headers,
  flags: [:end_headers, :end_stream],
  stream: 1,
  payload: Compressor.new.encode([%w(a b)]),
}

PRIORITY = {
  type: :priority,
  stream: 1,
  exclusive: false,
  stream_dependency: 0,
  weight: 20,
}

RST_STREAM = {
  type: :rst_stream,
  stream: 1,
  error: :stream_closed,
}

SETTINGS = {
  type: :settings,
  stream: 0,
  payload: [
    [:settings_max_concurrent_streams, 10],
    [:settings_initial_window_size, 0x7fffffff],
  ],
}

PUSH_PROMISE = {
  type: :push_promise,
  flags: [:end_headers],
  stream: 1,
  promise_stream: 2,
  payload: Compressor.new.encode([%w(a b)]),
}

PING = {
  stream: 0,
  type: :ping,
  payload: '12345678',
}

PONG = {
  stream: 0,
  type: :ping,
  flags: [:ack],
  payload: '12345678',
}

GOAWAY = {
  type: :goaway,
  last_stream: 2,
  error: :no_error,
  payload: 'debug',
}

WINDOW_UPDATE = {
  type: :window_update,
  increment: 10,
}

CONTINUATION = {
  type: :continuation,
  flags: [:end_headers],
  payload: '-second-block',
}

ALTSVC = {
  type: :altsvc,
  max_age: 1_402_290_402,    # 4
  port: 8080,                # 2    reserved 1
  proto: 'h2-12',            # 1 + 5
  host: 'www.example.com',   # 1 + 15
  origin: 'www.example.com', # 15
}

FRAME_TYPES = [
  DATA,
  HEADERS,
  PRIORITY,
  RST_STREAM,
  SETTINGS,
  PUSH_PROMISE,
  PING,
  GOAWAY,
  WINDOW_UPDATE,
  CONTINUATION,
  ALTSVC,
]

def set_stream_id(bytes, id)
  head = bytes.slice!(0, 9).unpack('CnCCN')
  head[4] = id

  head.pack('CnCCN') + bytes
end
