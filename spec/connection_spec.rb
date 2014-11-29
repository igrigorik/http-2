require "helper"

describe HTTP2::Connection do
  before(:each) do
    @conn = Client.new
  end

  let(:f) { Framer.new }

  context "initialization and settings" do
    it "should raise error if first frame is not SETTINGS" do
      (FRAME_TYPES - [SETTINGS]).each do |frame|
        frame = set_stream_id(f.generate(frame), 0x0)
        expect { @conn.dup << frame }.to raise_error(ProtocolError)
      end

      expect { @conn << f.generate(SETTINGS) }.to_not raise_error
      @conn.state.should eq :connected
    end

    it "should raise error if SETTINGS stream != 0" do
      frame = set_stream_id(f.generate(SETTINGS), 0x1)
      expect { @conn << frame }.to raise_error(ProtocolError)
    end
  end

  context "settings synchronization" do
    it "should reflect outgoing settings when ack is received" do
      @conn.local_settings[:settings_header_table_size].should eq 4096
      @conn.settings(settings_header_table_size: 256)
      @conn.local_settings[:settings_header_table_size].should eq 4096

      ack = { type: :settings, stream: 0, payload: [], flags: [:ack] }
      @conn << f.generate(ack)

      @conn.local_settings[:settings_header_table_size].should eq 256
    end

    it "should reflect incoming settings when SETTINGS is received" do
      @conn.remote_settings[:settings_header_table_size].should eq 4096
      settings = SETTINGS.dup
      settings[:payload] = [[:settings_header_table_size, 256]]

      @conn << f.generate(settings)

      @conn.remote_settings[:settings_header_table_size].should eq 256
    end

    it "should send SETTINGS ACK when SETTINGS is received" do
      settings = SETTINGS.dup
      settings[:payload] = [[:settings_header_table_size, 256]]

      @conn.should_receive(:send) do |frame|
        frame[:type].should eq :settings
        frame[:flags].should eq [:ack]
        frame[:payload].should eq []
      end

      @conn << f.generate(settings)
    end
  end

  context "stream management" do
    it "should initialize to default stream limit (100)" do
      @conn.local_settings[:settings_max_concurrent_streams].should eq 100
    end

    it "should change stream limit to received SETTINGS value" do
      @conn << f.generate(SETTINGS)
      @conn.remote_settings[:settings_max_concurrent_streams].should eq 10
    end

    it "should count open streams against stream limit" do
      s = @conn.new_stream
      @conn.active_stream_count.should eq 0
      s.receive HEADERS
      @conn.active_stream_count.should eq 1
    end

    it "should not count reserved streams against stream limit" do
      s1 = @conn.new_stream
      s1.receive PUSH_PROMISE
      @conn.active_stream_count.should eq 0

      s2 = @conn.new_stream
      s2.send PUSH_PROMISE
      @conn.active_stream_count.should eq 0

      # transition to half closed
      s1.receive HEADERS
      s2.send HEADERS
      @conn.active_stream_count.should eq 2

      # transition to closed
      s1.receive DATA
      s2.send DATA
      @conn.active_stream_count.should eq 0
    end

    it "should not exceed stream limit set by peer" do
      @conn << f.generate(SETTINGS)

      expect {
        10.times do
          s = @conn.new_stream
          s.send HEADERS
        end
      }.to_not raise_error

      expect { @conn.new_stream }.to raise_error(StreamLimitExceeded)
    end

    it "should initialize stream with HEADERS priority value" do
      @conn << f.generate(SETTINGS)

      stream, headers = nil, HEADERS.dup
      headers[:weight] = 20
      headers[:stream_dependency] = 0
      headers[:exclusive] = false

      @conn.on(:stream) {|s| stream = s }
      @conn << f.generate(headers)

      stream.weight.should eq 20
    end
  end

  context "Headers pre/post processing" do
    it "should not concatenate multiple occurences of a header field with the same name" do
      input = [
        ["Content-Type", "text/html"],
        ["Cache-Control", "max-age=60, private"],
        ["Cache-Control", "must-revalidate"],
      ]
      expected = [
        ["content-type", "text/html"],
        ["cache-control", "max-age=60, private"],
        ["cache-control", "must-revalidate"],
      ]
      headers = []
      @conn.on(:frame) do |bytes|
        bytes.force_encoding('binary')
        # bytes[3]: frame's type field
        [1,5,9].include?(bytes[3].ord) and headers << f.parse(bytes)
      end

      stream = @conn.new_stream
      stream.headers(input)

      headers.size.should eq 1
      emitted = Decompressor.new.decode(headers.first[:payload])
      emitted.should match_array(expected)
    end

    it "should not split zero-concatenated header field values" do
      input = [
        ["cache-control", "max-age=60, private\0must-revalidate"],
        ["content-type", "text/html"],
        ["cookie", "a=b\0c=d; e=f"],
      ]
      expected = [
        ["cache-control", "max-age=60, private\0must-revalidate"],
        ["content-type", "text/html"],
        ["cookie", "a=b\0c=d; e=f"],
      ]

      result = nil
      @conn.on(:stream) do |stream|
        stream.on(:headers) {|h| result = h}
      end

      srv = Server.new
      srv.on(:frame) {|bytes| @conn << bytes}
      stream = srv.new_stream
      stream.headers(input)

      result.should eq expected

    end
  end

  context "flow control" do
    it "should initialize to default flow window" do
      @conn.remote_window.should eq DEFAULT_FLOW_WINDOW
    end

    it "should update connection and stream windows on SETTINGS" do
      settings, data = SETTINGS.dup, DATA.dup
      settings[:payload] = [[:settings_initial_window_size, 1024]]
      data[:payload] = 'x'*2048

      stream = @conn.new_stream

      stream.send HEADERS
      stream.send data
      stream.remote_window.should eq (DEFAULT_FLOW_WINDOW - 2048)
      @conn.remote_window.should  eq (DEFAULT_FLOW_WINDOW - 2048)

      @conn << f.generate(settings)
      @conn.remote_window.should  eq -1024
      stream.remote_window.should eq -1024
    end

    it "should initialize streams with window specified by peer" do
      settings = SETTINGS.dup
      settings[:payload] = [[:settings_initial_window_size, 1024]]

      @conn << f.generate(settings)
      @conn.new_stream.remote_window.should eq 1024
    end

    it "should observe connection flow control" do
      settings, data = SETTINGS.dup, DATA.dup
      settings[:payload] = [[:settings_initial_window_size, 1000]]

      @conn << f.generate(settings)
      s1 = @conn.new_stream
      s2 = @conn.new_stream

      s1.send HEADERS
      s1.send data.merge({payload: "x" * 900})
      @conn.remote_window.should eq 100

      s2.send HEADERS
      s2.send data.merge({payload: "x" * 200})
      @conn.remote_window.should eq 0
      @conn.buffered_amount.should eq 100

      @conn << f.generate(WINDOW_UPDATE.merge({stream: 0, increment: 1000}))
      @conn.buffered_amount.should eq 0
      @conn.remote_window.should eq 900
    end
  end

  context "framing" do
    it "should buffer incomplete frames" do
      settings = SETTINGS.dup
      settings[:payload] = [[:settings_initial_window_size, 1000]]
      @conn << f.generate(settings)

      frame = f.generate(WINDOW_UPDATE.merge({stream: 0, increment: 1000}))
      @conn << frame
      @conn.remote_window.should eq 2000

      @conn << frame.slice!(0,1)
      @conn << frame
      @conn.remote_window.should eq 3000
    end

    it "should decompress header blocks regardless of stream state" do
      req_headers = [
        ["content-length", "20"],
        ["x-my-header", "first"]
      ]

      cc = Compressor.new
      headers = HEADERS.dup
      headers[:payload] = cc.encode(req_headers)

      @conn << f.generate(SETTINGS)
      @conn.on(:stream) do |stream|
        stream.should_receive(:<<) do |frame|
          frame[:payload].should eq req_headers
        end
      end

      @conn << f.generate(headers)
    end

    it "should decode non-contiguous header blocks" do
      req_headers = [
        ["content-length", "15"],
        ["x-my-header", "first"]
      ]

      cc = Compressor.new
      h1, h2 = HEADERS.dup, CONTINUATION.dup

      # Header block fragment might not complete for decompression
      payload = cc.encode(req_headers)
      h1[:payload] = payload.slice!(0, payload.size/2) # first half
      h1[:stream] = 5
      h1[:flags] = []

      h2[:payload] = payload # the remaining
      h2[:stream] = 5

      @conn << f.generate(SETTINGS)
      @conn.on(:stream) do |stream|
        stream.should_receive(:<<) do |frame|
          frame[:payload].should eq req_headers
        end
      end

      @conn << f.generate(h1)
      @conn << f.generate(h2)
    end

    it "should require that split header blocks are a contiguous sequence" do
      headers, continutation = HEADERS.dup, CONTINUATION.dup
      headers[:flags] = []

      @conn << f.generate(SETTINGS)
      @conn << f.generate(headers)
      (FRAME_TYPES - [CONTINUATION]).each do |frame|
        expect { @conn << f.generate(frame) }.to raise_error(ProtocolError)
      end
    end

    it "should raise compression error on encode of invalid frame" do
      @conn << f.generate(SETTINGS)
      stream = @conn.new_stream

      expect {
        stream.headers({"name" => Float::INFINITY})
      }.to raise_error(CompressionError)
    end

    it "should raise connection error on decode of invalid frame" do
      @conn << f.generate(SETTINGS)
      frame = f.generate(DATA.dup) # Receiving DATA on unopened stream 1 is an error.
      # Connection errors emit protocol error frames
      expect { @conn << frame }.to raise_error(ProtocolError)
    end

    it "should emit encoded frames via on(:frame)" do
      bytes = nil
      @conn.on(:frame) {|d| bytes = d }
      @conn.settings(settings_max_concurrent_streams: 10,
                     settings_initial_window_size: 0x7fffffff)

      bytes.should eq f.generate(SETTINGS)
    end

    it "should compress stream headers" do
      @conn.on(:frame) do |bytes|
        bytes.force_encoding('binary')
        bytes.should_not match('get')
        bytes.should_not match('http')
        bytes.should_not match('www.example.org') # should be huffman encoded
      end

      stream = @conn.new_stream
      stream.headers({
        ':method' => 'get',
        ':scheme' => 'http',
        ':authority' => 'www.example.org',
        ':path'   => '/resource'
      })
    end

    it "should generate CONTINUATION if HEADERS is too long" do
      headers = []
      @conn.on(:frame) do |bytes|
        bytes.force_encoding('binary')
        # bytes[3]: frame's type field
        [1,5,9].include?(bytes[3].ord) and headers << f.parse(bytes)
      end

      stream = @conn.new_stream
      stream.headers({
        ':method' => 'get',
        ':scheme' => 'http',
        ':authority' => 'www.example.org',
        ':path'   => '/resource',
        'custom' => 'q' * 44000,
      }, end_stream: true)
      headers.size.should eq 3
      headers[0][:type].should eq :headers
      headers[1][:type].should eq :continuation
      headers[2][:type].should eq :continuation
      headers[0][:flags].should eq [:end_stream]
      headers[1][:flags].should eq []
      headers[2][:flags].should eq [:end_headers]
    end

    it "should not generate CONTINUATION if HEADERS fits exactly in a frame" do
      headers = []
      @conn.on(:frame) do |bytes|
        bytes.force_encoding('binary')
        # bytes[3]: frame's type field
        [1,5,9].include?(bytes[3].ord) and headers << f.parse(bytes)
      end

      stream = @conn.new_stream
      stream.headers({
        ':method' => 'get',
        ':scheme' => 'http',
        ':authority' => 'www.example.org',
        ':path'   => '/resource',
        'custom' => 'q' * 18682, # this number should be updated when Huffman table is changed
      }, end_stream: true)
      headers[0][:length].should eq @conn.remote_settings[:settings_max_frame_size]
      headers.size.should eq 1
      headers[0][:type].should eq :headers
      headers[0][:flags].should include(:end_headers)
      headers[0][:flags].should include(:end_stream)
    end

    it "should not generate CONTINUATION if HEADERS fits exactly in a frame" do
      headers = []
      @conn.on(:frame) do |bytes|
        bytes.force_encoding('binary')
        # bytes[3]: frame's type field
        [1,5,9].include?(bytes[3].ord) and headers << f.parse(bytes)
      end

      stream = @conn.new_stream
      stream.headers({
        ':method' => 'get',
        ':scheme' => 'http',
        ':authority' => 'www.example.org',
        ':path'   => '/resource',
        'custom' => 'q' * 18682, # this number should be updated when Huffman table is changed
      }, end_stream: true)
      headers[0][:length].should eq @conn.remote_settings[:settings_max_frame_size]
      headers.size.should eq 1
      headers[0][:type].should eq :headers
      headers[0][:flags].should include(:end_headers)
      headers[0][:flags].should include(:end_stream)
    end

    it "should generate CONTINUATION if HEADERS exceed the max payload by one byte" do
      headers = []
      @conn.on(:frame) do |bytes|
        bytes.force_encoding('binary')
        [1,5,9].include?(bytes[3].ord) and headers << f.parse(bytes)
      end

      stream = @conn.new_stream
      stream.headers({
        ':method' => 'get',
        ':scheme' => 'http',
        ':authority' => 'www.example.org',
        ':path'   => '/resource',
        'custom' => 'q' * 18683, # this number should be updated when Huffman table is changed
      }, end_stream: true)
      headers[0][:length].should eq @conn.remote_settings[:settings_max_frame_size]
      headers[1][:length].should eq 1
      headers.size.should eq 2
      headers[0][:type].should eq :headers
      headers[1][:type].should eq :continuation
      headers[0][:flags].should eq [:end_stream]
      headers[1][:flags].should eq [:end_headers]
    end
  end

  context "connection management" do
    it "should raise error on invalid connection header" do
      srv = Server.new
      expect { srv << f.generate(SETTINGS) }.to raise_error(HandshakeError)

      srv = Server.new
      expect {
        srv << CONNECTION_PREFACE_MAGIC
        srv << f.generate(SETTINGS)
      }.to_not raise_error
    end

    it "should respond to PING frames" do
      @conn << f.generate(SETTINGS)
      @conn.should_receive(:send) do |frame|
        frame[:type].should eq :ping
        frame[:flags].should eq [:ack]
        frame[:payload].should eq "12345678"
      end

      @conn << f.generate(PING)
    end

    it "should fire callback on PONG" do
      @conn << f.generate(SETTINGS)

      pong = nil
      @conn.ping("12345678") {|d| pong = d }
      @conn << f.generate(PONG)
      pong.should eq "12345678"
    end

    it "should fire callback on receipt of GOAWAY" do
      last_stream, payload, error = nil
      @conn << f.generate(SETTINGS)
      @conn.on(:goaway) {|s,e,p| last_stream = s; error = e; payload = p}
      @conn << f.generate(GOAWAY.merge({last_stream: 17, payload: "test"}))

      last_stream.should eq 17
      error.should eq :no_error
      payload.should eq "test"
    end

    it "should raise error when opening new stream after sending GOAWAY" do
      @conn.goaway
      expect { @conn.new_stream }.to raise_error(ConnectionClosed)
    end

    it "should raise error when opening new stream after receiving GOAWAY" do
      @conn << f.generate(SETTINGS)
      @conn << f.generate(GOAWAY)
      expect { @conn.new_stream }.to raise_error(ConnectionClosed)
    end

    it "should process connection management frames after GOAWAY" do
      @conn << f.generate(SETTINGS)
      @conn << f.generate(HEADERS)
      @conn << f.generate(GOAWAY)
      @conn << f.generate(HEADERS.merge({stream: 7}))
      @conn << f.generate(PUSH_PROMISE)

      @conn.active_stream_count.should eq 1
    end

    it "should raise error on frame for invalid stream ID" do
      @conn << f.generate(SETTINGS)

      expect {
        @conn << f.generate(DATA.dup.merge({:stream => 31}))
      }.to raise_error(ProtocolError)
    end

    it "should send GOAWAY frame on connection error" do
      stream = @conn.new_stream

      @conn.should_receive(:encode) do |frame|
        frame[:type].should eq :settings
        [frame]
      end
      @conn.should_receive(:encode) do |frame|
        frame[:type].should eq :goaway
        frame[:last_stream].should eq stream.id
        frame[:error].should eq :protocol_error
        [frame]
      end

      expect { @conn << f.generate(DATA) }.to raise_error(ProtocolError)
    end
  end

  context "API" do
    it ".settings should emit SETTINGS frames" do
      @conn.should_receive(:send) do |frame|
        frame[:type].should eq :settings
        frame[:payload].should eq([
          [:settings_max_concurrent_streams, 10],
          [:settings_initial_window_size, 0x7fffffff],
        ])
        frame[:stream].should eq 0
      end

      @conn.settings(settings_max_concurrent_streams: 10,
                     settings_initial_window_size: 0x7fffffff)
    end

    it ".ping should generate PING frames" do
      @conn.should_receive(:send) do |frame|
        frame[:type].should eq :ping
        frame[:payload].should eq "somedata"
      end

      @conn.ping("somedata")
    end

    it ".goaway should generate GOAWAY frame with last processed stream ID" do
      @conn << f.generate(SETTINGS)
      @conn << f.generate(HEADERS.merge({stream: 17}))

      @conn.should_receive(:send) do |frame|
        frame[:type].should eq :goaway
        frame[:last_stream].should eq 17
        frame[:error].should eq :internal_error
        frame[:payload].should eq "payload"
      end

      @conn.goaway(:internal_error, "payload")
    end

  end
end
