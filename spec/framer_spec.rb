require "helper"

describe HTTP2::Framer do

  let(:f) { Framer.new }

  context "common header" do
    let(:frame) {
      {
        length: 4,
        type: :headers,
        flags: [:end_stream, :reserved, :end_headers],
        stream: 15,
      }
    }

    let(:bytes) { [0,0x04, 0x01, 0x7, 0x0000000F].pack("CnCCN") }

    it "should generate common 9 byte header" do
      f.commonHeader(frame).should eq bytes
    end

    it "should parse common 9 byte header" do
      f.readCommonHeader(Buffer.new(bytes)).should eq frame
    end

    it "should raise exception on invalid frame type" do
      expect {
        frame[:type] = :bogus
        f.commonHeader(frame)
      }.to raise_error(CompressionError, /invalid.*type/i)
    end

    it "should raise exception on invalid stream ID" do
      expect {
        frame[:stream] = Framer::MAX_STREAM_ID + 1
        f.commonHeader(frame)
      }.to raise_error(CompressionError, /stream/i)
    end

    it "should raise exception on invalid frame flag" do
      expect {
        frame[:flags] = [:bogus]
        f.commonHeader(frame)
      }.to raise_error(CompressionError, /frame flag/)
    end

    it "should raise exception on invalid frame size" do
      expect {
        frame[:length] = 2**14
        f.commonHeader(frame)
      }.to raise_error(CompressionError, /too large/)
    end
  end

  context "DATA" do
    it "should generate and parse bytes" do
      frame = {
        length: 4,
        type: :data,
        flags: [:end_stream, :reserved],
        stream: 1,
        payload: 'text'
      }

      bytes = f.generate(frame)
      bytes.should eq [0,0x4,0x0,0x3,0x1,*'text'.bytes].pack("CnCCNC*")

      f.parse(bytes).should eq frame
    end
  end

  context "HEADERS" do
    it "should generate and parse bytes" do
      frame = {
        length: 12,
        type: :headers,
        flags: [:end_stream, :reserved, :end_headers],
        stream: 1,
        payload: 'header-block'
      }

      bytes = f.generate(frame)
      bytes.should eq [0,0xc,0x1,0x7,0x1,*'header-block'.bytes].pack("CnCCNC*")
      f.parse(bytes).should eq frame
    end

    it "should carry an optional stream priority" do
      frame = {
        length: 16,
        type: :headers,
        flags: [:end_headers, :priority],
        stream: 1,
        priority: 15,
        payload: 'header-block'
      }

      bytes = f.generate(frame)
      bytes.should eq [0,0x10,0x1,0xc,0x1,0xf,*'header-block'.bytes].pack("CnCCNNC*")
      f.parse(bytes).should eq frame
    end
  end

  context "PRIORITY" do
    it "should generate and parse bytes" do
      frame = {
        length: 4,
        type: :priority,
        stream: 1,
        priority: 15
      }

      bytes = f.generate(frame)
      bytes.should eq [0,0x4,0x2,0x0,0x1,0xf].pack("CnCCNN")
      f.parse(bytes).should eq frame
    end
  end

  context "RST_STREAM" do
    it "should generate and parse bytes" do
      frame = {
        length: 4,
        type: :rst_stream,
        stream: 1,
        error: :stream_closed
      }

      bytes = f.generate(frame)
      bytes.should eq [0,0x4,0x3,0x0,0x1,0x5].pack("CnCCNN")
      f.parse(bytes).should eq frame
    end
  end

  context "SETTINGS" do
    let(:frame) {
      {
        length: 8,
        type: :settings,
        flags: [],
        stream: 0,
        payload: {
          settings_max_concurrent_streams: 10
        }
      }
    }

    it "should generate and parse bytes" do

      bytes = f.generate(frame)
      bytes.should eq [0,0x8,0x4,0x0,0x0,0x4,0xa].pack("CnCCNNN")
      f.parse(bytes).should eq frame
    end

    it "should ignore custom settings" do
      frame[:length] = 8*2
      frame[:payload] = {
        settings_max_concurrent_streams: 10,
        settings_initial_window_size:    20
      }

      buf = f.generate(frame.merge({55 => 30}))
      f.parse(buf).should eq frame
    end

    it "should raise exception on invalid stream ID" do
      expect {
        frame[:stream] = 1
        f.generate(frame)
      }.to raise_error(CompressionError, /Invalid stream ID/)
    end

    it "should raise exception on invalid setting" do
      expect {
        frame[:payload] = {random: 23}
        f.generate(frame)
      }.to raise_error(CompressionError, /Unknown settings ID/)
    end
  end

  context "PUSH_PROMISE" do
    it "should generate and parse bytes" do
      frame = {
        length: 11,
        type: :push_promise,
        flags: [:end_headers],
        stream: 1,
        promise_stream: 2,
        payload: 'headers'
      }

      bytes = f.generate(frame)
      bytes.should eq [0,0xb,0x5,0x4,0x1,0x2,*'headers'.bytes].pack("CnCCNNC*")
      f.parse(bytes).should eq frame
    end
  end

  context "PING" do
    let(:frame) {
      {
        length: 8,
        stream: 1,
        type: :ping,
        flags: [:pong],
        payload: '12345678'
      }
    }

    it "should generate and parse bytes" do
      bytes = f.generate(frame)
      bytes.should eq [0,0x8,0x6,0x1,0x1,*'12345678'.bytes].pack("CnCCNC*")
      f.parse(bytes).should eq frame
    end

    it "should raise exception on invalid payload" do
      expect {
        frame[:payload] = "1234"
        f.generate(frame)
      }.to raise_error(CompressionError, /Invalid payload size/)
    end
  end

  context "GOAWAY" do
    let(:frame) {
      {
        length: 13,
        stream: 1,
        type: :goaway,
        last_stream: 2,
        error: :no_error,
        payload: 'debug'
      }
    }

    it "should generate and parse bytes" do
      bytes = f.generate(frame)
      bytes.should eq [0,0xd,0x7,0x0,0x1,0x2,0x0,*'debug'.bytes].pack("CnCCNNNC*")
      f.parse(bytes).should eq frame
    end

    it "should treat debug payload as optional" do
      frame.delete :payload
      frame[:length] = 0x8

      bytes = f.generate(frame)
      bytes.should eq [0,0x8,0x7,0x0,0x1,0x2,0x0].pack("CnCCNNN")
      f.parse(bytes).should eq frame
    end
  end

  context "WINDOW_UPDATE" do
    it "should generate and parse bytes" do
      frame = {
        length: 4,
        type: :window_update,
        increment: 10
      }

      bytes = f.generate(frame)
      bytes.should eq [0,0x4,0x9,0x0,0x0,0xa].pack("CnCCNN")
      f.parse(bytes).should eq frame
    end
  end

  context "CONTINUATION" do
    it "should generate and parse bytes" do
      frame = {
        length: 12,
        type: :continuation,
        stream: 1,
        flags: [:end_stream, :end_headers],
        payload: 'header-block'
      }

      bytes = f.generate(frame)
      bytes.should eq [0,0xc,0xa,0x5,0x1,*'header-block'.bytes].pack("CnCCNC*")
      f.parse(bytes).should eq frame
    end
  end

  it "should determine frame length" do
    frames = [
      [{type: :data, stream: 1, flags: [:end_stream], payload: "abc"}, 3],
      [{type: :headers, stream: 1, payload: "abc"}, 3],
      [{type: :priority, stream: 3, priority: 30}, 4],
      [{type: :rst_stream, stream: 3, error: 100}, 4],
      [{type: :settings, payload: {settings_max_concurrent_streams: 10}}, 8],
      [{type: :push_promise, promise_stream: 5, payload: "abc"}, 7],
      [{type: :ping, payload: "blob"*2}, 8],
      [{type: :goaway, last_stream: 5, error: 20, payload: "blob"}, 12],
      [{type: :window_update, stream: 1, increment: 1024}, 4],
      [{type: :continuation, stream: 1, payload: "abc"}, 3]
    ]

    frames.each do |(frame, size)|
      bytes = f.generate(frame)
      bytes.slice(0,3).unpack("Cn")[1].should eq size
    end
  end

  it "should parse single frame at a time" do
    frames = [
      {type: :headers, stream: 1, payload: "headers"},
      {type: :data, stream: 1, flags: [:end_stream], payload: "abc"}
    ]

    buf = f.generate(frames[0]) << f.generate(frames[1])

    f.parse(buf).should eq frames[0]
    f.parse(buf).should eq frames[1]
  end

  it "should process full frames only" do
    frame = {type: :headers, stream: 1, payload: "headers"}
    bytes = f.generate(frame)

    f.parse(bytes[0...-1]).should be_nil
    f.parse(bytes).should eq frame
    bytes.should be_empty
  end

end
