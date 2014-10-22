require "helper"

describe HTTP2::Client do
  before(:each) do
    @client = Client.new
  end

  let(:f) { Framer.new }

  context "initialization and settings" do
    it "should return odd stream IDs" do
      @client.new_stream.id.should_not be_even
    end

    it "should emit connection header and SETTINGS on new client connection" do
      frames = []
      @client.on(:frame) { |bytes| frames << bytes }
      @client.ping("12345678")

      frames[0].should eq CONNECTION_HEADER
      f.parse(frames[1])[:type].should eq :settings
    end

    it "should initialize client with custom connection settings" do
      frames = []

      @client = Client.new(:settings_max_concurrent_streams => 200)
      @client.on(:frame) { |bytes| frames << bytes }
      @client.ping("12345678")

      frame = f.parse(frames[1])
      frame[:type].should eq :settings
      frame[:payload].should include([:settings_max_concurrent_streams, 200])
    end
  end

  context "push" do
    it "should disallow client initiated push" do
      expect do
        @client.promise({}) {}
      end.to raise_error(Exception)
    end

    it "should raise error on PUSH_PROMISE against stream 0" do
      expect {
        @client << set_stream_id(f.generate(PUSH_PROMISE), 0)
      }.to raise_error(ProtocolError)
    end

    it "should raise error on PUSH_PROMISE against bogus stream" do
      expect {
        @client << set_stream_id(f.generate(PUSH_PROMISE), 31415)
      }.to raise_error(ProtocolError)
    end

    it "should raise error on PUSH_PROMISE against non-idle stream" do
      expect {
        s = @client.new_stream
        s.send HEADERS

        @client << set_stream_id(f.generate(PUSH_PROMISE), s.id)
        @client << set_stream_id(f.generate(PUSH_PROMISE), s.id)
     }.to raise_error(ProtocolError)
    end

    it "should emit stream object for received PUSH_PROMISE" do
      s = @client.new_stream
      s.send HEADERS

      promise = nil
      @client.on(:promise) {|s| promise = s }
      @client << set_stream_id(f.generate(PUSH_PROMISE), s.id)

      promise.id.should eq 2
      promise.state.should eq :reserved_remote
    end

    it "should auto RST_STREAM promises against locally-RST stream" do
      s = @client.new_stream
      s.send HEADERS
      s.close

      @client.stub(:send)
      @client.should_receive(:send) do |frame|
        frame[:type].should eq :rst_stream
        frame[:stream].should eq 2
      end

      @client << set_stream_id(f.generate(PUSH_PROMISE), s.id)
    end
  end

end
