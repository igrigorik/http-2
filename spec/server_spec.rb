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
