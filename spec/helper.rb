require 'http/2'
require 'json'
require 'coveralls'

Coveralls.wear! if ENV["CI"]

include HTTP2
include HTTP2::Header
include HTTP2::Error

DATA = {
  type: :data,
  flags: [:end_stream],
  stream: 1,
  payload: 'text'
}

HEADERS = {
  type: :headers,
  flags: [:end_headers],
  stream: 1,
  payload: 'header-block'
}

HEADERS_END_STREAM = {
  type: :headers,
  flags: [:end_headers, :end_stream],
  stream: 1,
  payload: 'header-block'
}

PRIORITY = {
  type: :priority,
  stream: 1,
  priority: 15
}

RST_STREAM = {
  type: :rst_stream,
  stream: 1,
  error: :stream_closed
}

SETTINGS = {
  type: :settings,
  stream: 0,
  payload: {
    settings_max_concurrent_streams: 10,
    settings_flow_control_options: 1
  }
}

PUSH_PROMISE = {
  type: :push_promise,
  flags: [:end_push_promise],
  stream: 1,
  promise_stream: 2,
  payload: 'headers'
}

PING = {
  stream: 0,
  type: :ping,
  payload: '12345678'
}

PONG = {
  stream: 0,
  type: :ping,
  flags: [:pong],
  payload: '12345678'
}

GOAWAY = {
  type: :goaway,
  last_stream: 2,
  error: :no_error,
  payload: 'debug'
}

WINDOW_UPDATE = {
  type: :window_update,
  increment: 10
}

CONTINUATION = {
  type: :continuation,
  flags: [:end_headers],
  payload: '-second-block'
}

FRAME_TYPES = [
  DATA, HEADERS, PRIORITY, RST_STREAM, SETTINGS, PUSH_PROMISE,
  PING, GOAWAY, WINDOW_UPDATE, CONTINUATION
]

def new_connection(type = :client)
  conn = Connection.new(type)
  conn << CONNECTION_HEADER if type == :server
  conn
end

def set_stream_id(bytes, id)
  head = bytes.slice!(0,8).unpack('nCCN')
  head[3] = id

  head.pack('nCCN') + bytes
end
