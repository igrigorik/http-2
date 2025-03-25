# frozen_string_literal: true

require "uri"
require "http/2"

DEBUG = ENV.key?("DEBUG")
BENCHMARK = ENV.fetch("BENCH", "profile")
ITERATIONS = 5000

METHOD = "GET"
BODY = "bang"
URL = URI.parse(ARGV[0] || "http://localhost:8080/")
CLIENT = HTTP2::Client.new
SERVER = HTTP2::Server.new

CLIENT_BUFFER = "".b
SERVER_BUFFER = "".b

def log
  return unless DEBUG

  puts yield
end

log { "build client..." }
CLIENT.on(:frame) do |bytes|
  log { "(client) sending bytes: #{bytes.size}" }
  CLIENT_BUFFER << bytes
end
CLIENT.on(:frame_sent) do |frame|
  log { "(client) Sent frame: #{frame.inspect}" }
end
CLIENT.on(:frame_received) do |frame|
  log { "(client) Received frame: #{frame.inspect}" }
end

CLIENT.on(:altsvc) do |f|
  log { "(client) received ALTSVC #{f}" }
end

log { "build server..." }
SERVER.on(:frame) do |bytes|
  log { "(server) sending bytes: #{bytes.bytesize}" }
  SERVER_BUFFER << bytes
end
SERVER.on(:frame_sent) do |frame|
  log { "(server) Sent frame: #{frame.inspect}" }
end
SERVER.on(:frame_received) do |frame|
  log { "(server) Received frame: #{frame.inspect}" }
end

SERVER.on(:goaway) do
  log { "(server) goaway received" }
end

SERVER.on(:stream) do |stream|
  req = {}
  buffer = "".b

  stream.on(:active) { log { "(server stream:#{stream.id}) client opened new stream" } }
  stream.on(:close)  { log { "(server stream:#{stream.id}) stream closed" } }

  stream.on(:headers) do |h|
    log { "(server stream:#{stream.id}) request headers: #{Hash[*h.flatten]}" }
  end

  stream.on(:data) do |d|
    log { "(server stream:#{stream.id}) payload chunk: <<#{d}>>" }
    buffer << d
  end

  stream.on(:half_close) do
    log { "(server stream:#{stream.id}) client closed its end of the stream" }

    response = nil
    if req[":method"] == "POST"
      log { "(server stream:#{stream.id}) Received POST request, payload: #{buffer}" }
      response = "(server stream:#{stream.id}) Hello HTTP 2.0! POST payload: #{buffer}"
    else
      log { "Received GET request" }
      response = "(server stream:#{stream.id}) Hello HTTP 2.0! GET request"
    end

    stream.headers(
      {
        ":status" => "200",
        "content-length" => response.bytesize.to_s,
        "content-type" => "text/plain",
        "x-stream-id" => "stream-#{stream.id}"
      }, end_stream: false
    )

    # split response into multiple DATA frames
    stream.data(response[0, 5], end_stream: false)
    stream.data(response[5, -1] || "")
  end
end

def send_request
  stream = CLIENT.new_stream

  stream.on(:close) do
    log { "(client stream:#{stream.id}) stream closed" }
  end

  stream.on(:half_close) do
    log { "(client stream:#{stream.id}) closing client-end of the stream" }
  end

  stream.on(:headers) do |h|
    log { "(client stream:#{stream.id}) response headers: #{h}" }
  end

  stream.on(:data) do |d|
    log { "(client stream:#{stream.id}) response data chunk: <<#{d}>>" }
  end

  stream.on(:altsvc) do |f|
    log { "(client stream:#{stream.id}) received ALTSVC #{f}" }
  end

  head = {
    ":scheme" => URL.scheme,
    ":method" => METHOD,
    ":authority" => [URL.host, URL.port].join(":"),
    ":path" => URL.path,
    "accept" => "*/*"
  }

  log { "Sending HTTP 2.0 request" }

  if head[":method"] == "GET"
    stream.headers(head, end_stream: true)
  else
    stream.headers(head, end_stream: false)
    stream.data(BODY)
  end

  until CLIENT_BUFFER.empty? && SERVER_BUFFER.empty?
    unless CLIENT_BUFFER.empty?
      SERVER << CLIENT_BUFFER
      CLIENT_BUFFER.clear
    end

    unless SERVER_BUFFER.empty?
      CLIENT << SERVER_BUFFER
      SERVER_BUFFER.clear
    end
  end
end

def benchmark(bench_type, &block)
  return yield if DEBUG

  case bench_type
  when "profile"
    require "singed"
    Singed.output_directory = "tmp/"

    flamegraph(&block)
  when "memory"
    require "memory_profiler"
    MemoryProfiler.report(allow_files: ["lib/http/2"], &block).pretty_print

  when "benchmark"
    require "benchmark"
    puts Benchmark.measure(&block)
  end
end

GC.start
GC.disable

puts "warmup..."
ITERATIONS.times do
  # start client stream
  send_request
end

puts "bench!"
# Benchmark.bmbm do |x|
benchmark(BENCHMARK) do
  ITERATIONS.times do
    # start client stream
    send_request
  end

  CLIENT.goaway
end
