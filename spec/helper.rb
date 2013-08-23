require 'net/http2'

include Net::HTTP2
include Net::HTTP2::Header


DATA = {
  type: :data,
  flags: [:end_stream, :reserved],
  stream: 1,
  payload: 'text'
}

HEADERS = {
  type: :headers,
  flags: [:reserved, :end_headers],
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
    settings_max_concurrent_streams: 10
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
  stream: 1,
  type: :ping,
  flags: [:pong],
  payload: '12345678'
}

GOAWAY = {
  stream: 1,
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
  stream: 1,
  flags: [:end_stream, :end_headers],
  payload: 'header-block'
}

FRAME_TYPES = [
  DATA, HEADERS, PRIORITY, RST_STREAM, SETTINGS, PUSH_PROMISE,
  PING, GOAWAY, WINDOW_UPDATE, CONTINUATION
]
