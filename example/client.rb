require_relative 'helper'

Addrinfo.tcp("localhost", 8080).connect do |sock|
  conn = HTTP2::Connection.new(:client)
  conn.on(:frame) do |bytes|
    puts "Sending bytes: #{bytes.inspect}"
    sock.print bytes
    sock.flush
  end

  stream = conn.new_stream
  log = Logger.new(stream.id)

  stream.on(:close) do
   log.info "stream closed"
   sock.close
 end

 stream.on(:half_close) do
  log.info "closing client-end of the stream"
 end

  stream.on(:headers) do |h|
    log.info "response headers: #{h}"
  end

  stream.on(:data) do |d|
    log.info "response data chunk: <<#{d}>>"
  end

  puts "Sending POST request"
  stream.headers({
    ":method" => "post",
    ":host" => "localhost",
    ":path" => "/resource",
    "accept" => "*/*"
  })

  stream.data("woot!")

  while !sock.closed? && !sock.eof?
    data = sock.readpartial(1024)
    puts "Received bytes: #{data.inspect}"
    conn << data
  end
end
