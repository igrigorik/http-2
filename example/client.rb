require_relative 'helper'

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: client.rb [options]"

  opts.on("-d", "--data [String]", "HTTP payload") do |v|
    options[:payload] = v
  end
end.parse!


uri = URI.parse(ARGV[0] || 'http://localhost:8080/')

Addrinfo.tcp(uri.host, uri.port).connect do |sock|
  conn = HTTP2::Client.new
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

  head = {
    ":scheme" => uri.scheme,
    ":method" => (options[:payload].nil? ? "get" : "post"),
    ":host" => [uri.host, uri.port].join,
    ":path" => uri.path,
    "accept" => "*/*"
  }

  puts "Sending HTTP 2.0 request"
  if head[":method"] == "get"
    stream.headers(head, end_stream: true)
  else
    stream.headers(head, end_stream: false)
    stream.data(options[:payload])
  end


  while !sock.closed? && !sock.eof?
    data = sock.readpartial(1024)
    puts "Received bytes: #{data.inspect}"

    begin
      conn << data
    rescue Exception => e
      puts "Exception: #{e}, #{e.message} - closing socket."
      sock.close
    end
  end
end
