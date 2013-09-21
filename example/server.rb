require_relative 'helper'

puts "Starting server on port 8080"
Socket.tcp_server_loop(8080) do |sock|
  puts "New TCP connection!"

  conn = HTTP2::Connection.new(:server)
  conn.on(:frame) do |bytes|
    puts "Writing bytes: #{bytes.inspect}"
    sock.write bytes
  end

  conn.on(:stream) do |stream|
    log = Logger.new(stream.id)
    buffer = ""

    stream.on(:active) { log.info "cliend opened new stream" }
    stream.on(:close)  { log.info "stream closed" }

    stream.on(:headers) do |h|
      log.info "request headers: #{h}"
    end

    stream.on(:data) do |d|
      log.info "payload chunk: <<#{d}>>"
      buffer << d
    end

    stream.on(:half_close) do
      log.info "client closed its end of the stream, " +
               "payload size: #{buffer.size}"

      response = "Hello HTTP 2.0! echo: #{buffer}"
      stream.headers({
        ":status" => "200",
        "content-length" => response.bytesize.to_s,
        "content-type" => "text/plain"
      }, end_stream: false)

      # split response into multiple DATA frames
      stream.data(response.slice!(0,5), end_stream: false)
      stream.data(response)
    end
  end

  while !sock.closed? && !sock.eof?
    data = sock.readpartial(1024)
    conn << data
  end
end
