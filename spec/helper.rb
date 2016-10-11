require './spec/support/deep_dup'

RSpec.configure(&:disable_monkey_patching!)
RSpec::Expectations.configuration.warn_about_potential_false_positives = false

require 'json'
require 'coveralls'

Coveralls.wear! if ENV['CI']

require 'http/2'

include HTTP2
include HTTP2::Header
include HTTP2::Error

DATA = {
  type: :data,
  flags: [:end_stream].freeze,
  stream: 1,
  payload: 'text'.freeze,
}.freeze

HEADERS = {
  type: :headers,
  flags: [:end_headers].freeze,
  stream: 1,
  payload: Compressor.new.encode([%w(a b)]).freeze,
}.freeze

HEADERS_END_STREAM = {
  type: :headers,
  flags: [:end_headers, :end_stream].freeze,
  stream: 1,
  payload: Compressor.new.encode([%w(a b)]).freeze,
}.freeze

PRIORITY = {
  type: :priority,
  stream: 1,
  exclusive: false,
  stream_dependency: 0,
  weight: 20,
}.freeze

RST_STREAM = {
  type: :rst_stream,
  stream: 1,
  error: :stream_closed,
}.freeze

SETTINGS = {
  type: :settings,
  stream: 0,
  payload: [
    [:settings_max_concurrent_streams, 10].freeze,
    [:settings_initial_window_size, 0x7fffffff].freeze,
  ].freeze,
}.freeze

PUSH_PROMISE = {
  type: :push_promise,
  flags: [:end_headers].freeze,
  stream: 1,
  promise_stream: 2,
  payload: Compressor.new.encode([%w(a b)]).freeze,
}.freeze

PING = {
  stream: 0,
  type: :ping,
  payload: '12345678'.freeze,
}.freeze

PONG = {
  stream: 0,
  type: :ping,
  flags: [:ack].freeze,
  payload: '12345678'.freeze,
}.freeze

GOAWAY = {
  type: :goaway,
  last_stream: 2,
  error: :no_error,
  payload: 'debug'.freeze,
}.freeze

WINDOW_UPDATE = {
  type: :window_update,
  increment: 10,
}.freeze

CONTINUATION = {
  type: :continuation,
  flags: [:end_headers].freeze,
  payload: '-second-block'.freeze,
}.freeze

ALTSVC = {
  type: :altsvc,
  max_age: 1_402_290_402,           # 4
  port: 8080,                       # 2    reserved 1
  proto: 'h2-12'.freeze,            # 1 + 5
  host: 'www.example.com'.freeze,   # 1 + 15
  origin: 'www.example.com'.freeze, # 15
}.freeze

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
].freeze

def set_stream_id(bytes, id)
  scheme = 'CnCCN'.freeze
  head = bytes.slice!(0, 9).unpack(scheme)
  head[4] = id

  head.pack(scheme) + bytes
end
