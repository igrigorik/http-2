require "helper"

describe Http2::Parser::Framer do

  let(:f) { Framer.new }

  context "common header" do
    let(:frame) {
      {
        length: 4,
        type: :headers,
        flags: [:endstream, :reserved, :endheaders],
        stream: 15
      }
    }

    let(:bytes) { [0x04, 0x01, 0x16, 0x0000000F].pack("SCCL") }

    it "should generate common 8 byte header" do
      f.commonHeader(frame).should eq bytes
    end

    it "should parse common 8 byte header" do
      f.parse(StringIO.new(bytes)).should eq frame
    end

    it "should raise exception on invalid frame type" do
      expect {
        frame[:type] = :bogus
        f.commonHeader(frame)
      }.to raise_error(FramingException, /invalid.*type/i)
    end

    it "should raise exception on invalid stream ID" do
      expect {
        frame[:stream] = Framer::MAX_STREAM_ID + 1
        f.commonHeader(frame)
      }.to raise_error(FramingException, /stream/i)
    end

    it "should raise exception on invalid frame flag" do
      expect {
        frame[:flags] = [:bogus]
        f.commonHeader(frame)
      }.to raise_error(FramingException, /frame flag/)
    end

    it "should raise exception on invalid frame size" do
      expect {
        frame[:length] = 2**16
        f.commonHeader(frame)
      }.to raise_error(FramingException, /too large/)
    end
  end

end
