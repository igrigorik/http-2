# HTTP-2

Pure-Ruby, transport-agnostic implementation of [HTTP 2.0 protocol](http://tools.ietf.org/html/draft-ietf-httpbis-http2) (see [HPBN chapter](http://chimera.labs.oreilly.com/books/1230000000545/ch12.html) for overview):

* [Binary framing](http://chimera.labs.oreilly.com/books/1230000000545/ch12.html#_binary_framing_layer) parser and encoder
* [Stream multiplexing](http://chimera.labs.oreilly.com/books/1230000000545/ch12.html#HTTP2_STREAMS_MESSAGES_FRAMES) and [prioritization](http://chimera.labs.oreilly.com/books/1230000000545/ch12.html#HTTP2_PRIORITIZATION)
* Connection and stream [flow control](http://chimera.labs.oreilly.com/books/1230000000545/ch12.html#_flow_control)
* [Header compression](http://chimera.labs.oreilly.com/books/1230000000545/ch12.html#HTTP2_HEADER_COMPRESSION)
* Other HTTP 2.0 goodies...

Current implementation is based on:

* [draft-ietf-httpbis-http2-06](http://tools.ietf.org/html/draft-ietf-httpbis-http2-06)
* [draft-ietf-httpbis-header-compression-01](http://tools.ietf.org/html/draft-ietf-httpbis-header-compression)

Since the underlying specifications are still evolving, treat this implementation as a work in progress also!

## Getting started

This implementation makes no assumptions as how the data is delivered: it could be a regular Ruby TCP socket, your custom eventloop, or whatever other transport you wish to use - e.g. ZeroMQ, [avian carriers](http://www.ietf.org/rfc/rfc1149.txt), etc.

Your transport is responsible for feeding data to the parser, which performs all of the necessary HTTP 2.0 decoding, state management and the rest, and vice versa, the parser will emit bytes (encoded HTTP 2.0 frames) that you can then route to the destination. A quick example is in order:

```ruby
sock = TCPSocket.new '132.12.12.13', 80
conn = HTTP2::Connection.new(:client)

# process inbound stream
conn.on(:stream) do |stream|
  stream.on(:headers) { |h| ... }
  stream.on(:data) { |d| ... }

  # ... send response
  stream.headers({
    ":status" => 200,
    "content-length" => 132,
    "content-type" => "application/json"
  })

  stream.data(first_chunk, end_stream: false)
  stream.data(last_chunk)
end

# send encoded HTTP 2.0 frames
conn.on(:frame) do |bytes|
  sock.write bytes
end

while line = sock.gets
  conn << line
end
```


### License

(MIT License) - Copyright (c) 2013 Ilya Grigorik
