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
  end

  context "flow control" do
    it "should initialize to default flow window" do
      @conn.window.should eq DEFAULT_FLOW_WINDOW
    end

    it "should observe stream flow control"
    it "should observe connection flow control"

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
  end

  context "framing" do
    it "should buffer incomplete received frames"
    it "should apply header (de)compression"
    it "should split large HEADERS frames"
    it "should split large PUSH_PROMISE frames"
    it "should split large DATA frames"
  end

  context "connection management" do
    it "should generate PING frames"
    it "should respond to PING frames"
    it "should close connection on GOAWAY"
  end
end
