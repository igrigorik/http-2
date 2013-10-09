require "helper"

describe HTTP2::Server do
  before(:each) do
    @srv = Server.new
  end

  let(:f) { Framer.new }

  context "initialization and settings" do
    it "should return even stream IDs" do
      @srv.new_stream.id.should be_even
    end

    it "should emit SETTINGS on new connection" do
      frames = []
      @srv.on(:frame) { |recv| frames << recv }
      @srv << CONNECTION_HEADER

      f.parse(frames[0])[:type].should eq :settings
    end

    it "should initialize client with custom connection settings" do
      frames = []

      @srv = Server.new(streams: 200, window: 2**10)
      @srv.on(:frame) { |recv| frames << recv }
      @srv << CONNECTION_HEADER

      frame = f.parse(frames[0])
      frame[:type].should eq :settings
      frame[:payload][:settings_max_concurrent_streams].should eq 200
      frame[:payload][:settings_initial_window_size].should eq 2**10
    end
  end

  it "should allow server push" do
    client = Client.new
    client.on(:frame) { |bytes| @srv << bytes }

    @srv.on(:stream) do |stream|
      expect {
        stream.promise({}) {}
      }.to_not raise_error
    end

    client.new_stream
    client.send HEADERS
  end
end
