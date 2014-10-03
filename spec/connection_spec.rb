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

  context "stream management" do
    it "should initialize to default stream limit (100)" do
      @conn.stream_limit.should eq 100
    end

    it "should change stream limit to received SETTINGS value" do
      @conn << f.generate(SETTINGS)
      @conn.stream_limit.should eq 10
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
      headers[:priority] = 20

      @conn.on(:stream) {|s| stream = s }
      @conn << f.generate(headers)

      stream.priority.should eq 20
    end
  end

  context "flow control" do
    it "should initialize to default flow window" do
      @conn.window.should eq DEFAULT_FLOW_WINDOW
    end

    it "should update connection and stream windows on SETTINGS" do
      settings, data = SETTINGS.dup, DATA.dup
      settings[:payload] = { settings_initial_window_size: 1024 }
      data[:payload] = 'x'*2048

      stream = @conn.new_stream

      stream.send HEADERS
      stream.send data
      stream.window.should eq (DEFAULT_FLOW_WINDOW - 2048)
      @conn.window.should  eq (DEFAULT_FLOW_WINDOW - 2048)

      @conn << f.generate(settings)
      @conn.window.should  eq -1024
      stream.window.should eq -1024
    end

    it "should initialize streams with window specified by peer" do
      settings = SETTINGS.dup
      settings[:payload] = { settings_initial_window_size: 1024 }

      @conn << f.generate(settings)
      @conn.new_stream.window.should eq 1024
    end

    it "should support global disable of flow control" do
      @conn << f.generate(SETTINGS)
      @conn.window.should eq Float::INFINITY
    end

    it "should raise error on flow control after disabling it" do
      expect { @conn << f.generate(SETTINGS) }.to_not raise_error
      expect {
        [WINDOW_UPDATE, SETTINGS].each do |frame|
          @conn.dup << f.generate(frame)
        end
      }.to raise_error(FlowControlError)
    end

    it "should observe connection flow control" do
      settings, data = SETTINGS.dup, DATA.dup
      settings[:payload] = { settings_initial_window_size: 1000 }

      @conn << f.generate(settings)
      s1 = @conn.new_stream
      s2 = @conn.new_stream

      s1.send HEADERS
      s1.send data.merge({payload: "x" * 900})
      @conn.window.should eq 100

      s2.send HEADERS
      s2.send data.merge({payload: "x" * 200})
      @conn.window.should eq 0
      @conn.buffered_amount.should eq 100

      @conn << f.generate(WINDOW_UPDATE.merge({stream: 0, increment: 1000}))
      @conn.buffered_amount.should eq 0
      @conn.window.should eq 900
    end
  end

  context "framing" do
    it "should buffer incomplete frames" do
      settings = SETTINGS.dup
      settings[:payload] = { settings_initial_window_size: 1000 }
      @conn << f.generate(settings)

      frame = f.generate(WINDOW_UPDATE.merge({stream: 0, increment: 1000}))
      @conn << frame
      @conn.window.should eq 2000

      @conn << frame.slice!(0,1)
      @conn << frame
      @conn.window.should eq 3000
    end

    it "should decompress header blocks regardless of stream state" do
      req_headers = [
        ["content-length", "20"],
        ["x-my-header", "first"]
      ]

      cc = Compressor.new(:response)
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

      cc = Compressor.new(:response)
      h1, h2 = HEADERS.dup, CONTINUATION.dup
      h1[:payload] = cc.encode([req_headers.first])
      h1[:stream] = 5
      h1[:flags] = []

      h2[:payload] = cc.encode([req_headers.last])
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

    it "should raise connection error on encode exception" do
      @conn << f.generate(SETTINGS)
      stream = @conn.new_stream

      expect {
        stream.headers({"name" => Float::INFINITY})
      }.to raise_error(CompressionError)
    end

    it "should raise connection error on decode exception" do
      @conn << f.generate(SETTINGS)
      frame = f.generate(HEADERS.dup)
      frame[2] = 0.chr

      expect { @conn << frame }.to raise_error(ProtocolError)
    end

    it "should emit encoded frames via on(:frame)" do
      bytes = nil
      @conn.on(:frame) {|d| bytes = d }
      @conn.settings(stream_limit: 10, window_limit: Float::INFINITY)

      bytes.should eq f.generate(SETTINGS)
    end

    it "should compress stream headers" do
      @conn.ping("12345678")
      @conn.on(:frame) do |bytes|
        bytes.force_encoding('binary')
        bytes.should_not match('get')
        bytes.should_not match('http')
        bytes.should match('www.example.org')
      end

      stream = @conn.new_stream
      stream.headers({
        ':method' => 'get',
        ':scheme' => 'http',
        ':host'   => 'www.example.org',
        ':path'   => '/resource'
      })
    end
  end

  context "connection management" do
    it "should raise error on invalid connection header" do
      srv = Server.new
      expect { srv << f.generate(SETTINGS) }.to raise_error(HandshakeError)

      srv = Server.new
      expect {
        srv << CONNECTION_HEADER
        srv << f.generate(SETTINGS)
      }.to_not raise_error
    end

    it "should respond to PING frames" do
      @conn << f.generate(SETTINGS)
      @conn.should_receive(:send) do |frame|
        frame[:type].should eq :ping
        frame[:flags].should eq [:pong]
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

      @conn.stub(:encode)
      @conn.should_receive(:encode) do |frame|
        frame[:type].should eq :goaway
        frame[:last_stream].should eq stream.id
        frame[:error].should eq :protocol_error
      end

      @conn << f.generate(SETTINGS)
      expect { @conn << f.generate(DATA) }.to raise_error(ProtocolError)
    end
  end

  context "API" do
    it ".settings should emit SETTINGS frames" do
      @conn.should_receive(:send) do |frame|
        frame[:type].should eq :settings
        frame[:payload].should eq({
          settings_max_concurrent_streams: 10,
          settings_flow_control_options: 1
        })
        frame[:stream].should eq 0
      end

      @conn.settings(stream_limit: 10, window_limit: Float::INFINITY)
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
