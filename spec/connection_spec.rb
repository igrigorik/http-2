require "helper"

describe Net::HTTP2::Connection do
  before(:each) do
    @conn = Connection.new
  end

  let(:f) { Framer.new }

  context "initialization and settings" do
    it "should return odd ids for client requests" do
      @conn = Connection.new(:client)
      @conn.new_stream.id.should_not be_even

      @conn = Connection.new(:server)
      @conn.new_stream.id.should be_even
    end

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
    it "should initialize to default stream limit (infinite)" do
      @conn.stream_limit.should eq Float::INFINITY
    end

    it "should change stream limit to received SETTINGS value" do
      @conn << f.generate(SETTINGS)
      @conn.stream_limit.should eq 10
    end

    it "should count open streams against stream limit" do
      s = @conn.new_stream
      @conn.active_stream_count.should eq 0
      s.process HEADERS
      @conn.active_stream_count.should eq 1
    end

    it "should not count reserved streams against stream limit" do
      s1 = @conn.new_stream
      s1.process PUSH_PROMISE
      @conn.active_stream_count.should eq 0

      s2 = @conn.new_stream
      s2.send PUSH_PROMISE
      @conn.active_stream_count.should eq 0

      # transition to half closed
      s1.process HEADERS
      s2.send HEADERS
      @conn.active_stream_count.should eq 2

      # transition to closed
      s1.process DATA
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

    context "push" do
      it "should raise error on PUSH_PROMISE against stream 0" do
        expect {
          @conn << set_stream_id(f.generate(PUSH_PROMISE), 0)
        }.to raise_error(ProtocolError)
      end

      it "should raise error on PUSH_PROMISE against bogus stream" do
        expect {
          @conn << set_stream_id(f.generate(PUSH_PROMISE), 31415)
        }.to raise_error(ProtocolError)
      end

      it "should raise error on PUSH_PROMISE against non-idle stream" do
        expect {
          s = @conn.new_stream
          s.send HEADERS

          @conn << set_stream_id(f.generate(PUSH_PROMISE), s.id)
          @conn << set_stream_id(f.generate(PUSH_PROMISE), s.id)
       }.to raise_error(ProtocolError)
      end

      it "should emit stream object for received PUSH_PROMISE" do
        s = @conn.new_stream
        s.send HEADERS

        promise = nil
        @conn.on(:promise) {|s| promise = s }
        @conn << set_stream_id(f.generate(PUSH_PROMISE), s.id)

        promise.id.should eq 2
        promise.state.should eq :reserved_remote
      end

      it "should auto RST_STREAM promises against locally-RST stream" do
        s = @conn.new_stream
        s.send HEADERS
        s.close

        @conn.stub(:process)
        @conn.should_receive(:process) do |frame|
          frame[:type].should eq :rst_stream
          frame[:stream].should eq 2
        end

        @conn << set_stream_id(f.generate(PUSH_PROMISE), s.id)
      end
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

    it "should decompress header blocks regardless of stream state"
    it "should require that split header blocks is a contiguous sequence"
    it "should decode non-contiguous header blocks"

  end

  context "connection management" do
    it "should generate PING frames"
    it "should respond to PING frames"
    it "should close connection on GOAWAY"
  end
end
