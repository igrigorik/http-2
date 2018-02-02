require 'helper'

RSpec.describe HTTP2::Client do
  before(:each) do
    @client = Client.new
  end

  let(:f) { Framer.new }

  context 'initialization and settings' do
    it 'should return odd stream IDs' do
      expect(@client.new_stream.id).not_to be_even
    end

    it 'should emit connection header and SETTINGS on new client connection' do
      frames = []
      @client.on(:frame) { |bytes| frames << bytes }
      @client.ping('12345678')

      expect(frames[0]).to eq CONNECTION_PREFACE_MAGIC
      expect(f.parse(frames[1])[:type]).to eq :settings
    end

    it 'should initialize client with custom connection settings' do
      frames = []

      @client = Client.new(settings_max_concurrent_streams: 200)
      @client.on(:frame) { |bytes| frames << bytes }
      @client.ping('12345678')

      frame = f.parse(frames[1])
      expect(frame[:type]).to eq :settings
      expect(frame[:payload]).to include([:settings_max_concurrent_streams, 200])
    end
  end

  context 'upgrade' do
    it 'fails when client has already created streams' do
      @client.new_stream
      expect { @client.upgrade }.to raise_error(HTTP2::Error::ProtocolError)
    end

    it 'sends the preface' do
      expect(@client).to receive(:send_connection_preface)
      @client.upgrade
    end

    it 'initializes the first stream in the half-closed state' do
      stream = @client.upgrade
      expect(stream.state).to be(:half_closed_local)
    end
  end

  context 'push' do
    it 'should disallow client initiated push' do
      expect do
        @client.promise({}) {}
      end.to raise_error(NoMethodError)
    end

    it 'should raise error on PUSH_PROMISE against stream 0' do
      expect do
        @client << set_stream_id(f.generate(PUSH_PROMISE.dup), 0)
      end.to raise_error(ProtocolError)
    end

    it 'should raise error on PUSH_PROMISE against bogus stream' do
      expect do
        @client << set_stream_id(f.generate(PUSH_PROMISE.dup), 31_415)
      end.to raise_error(ProtocolError)
    end

    it 'should raise error on PUSH_PROMISE against non-idle stream' do
      expect do
        s = @client.new_stream
        s.send HEADERS.dup

        @client << set_stream_id(f.generate(PUSH_PROMISE.dup), s.id)
        @client << set_stream_id(f.generate(PUSH_PROMISE.dup), s.id)
      end.to raise_error(ProtocolError)
    end

    it 'should emit stream object for received PUSH_PROMISE' do
      s = @client.new_stream
      s.send HEADERS.deep_dup

      promise = nil
      @client.on(:promise) { |stream| promise = stream }
      @client << set_stream_id(f.generate(PUSH_PROMISE.deep_dup), s.id)

      expect(promise.id).to eq 2
      expect(promise.state).to eq :reserved_remote
    end

    it 'should emit promise headers for received PUSH_PROMISE' do
      header = nil
      s = @client.new_stream
      s.send HEADERS.deep_dup

      @client.on(:promise) do |stream|
        stream.on(:promise_headers) do |h|
          header = h
        end
      end
      @client << set_stream_id(f.generate(PUSH_PROMISE.deep_dup), s.id)

      expect(header).to be_a(Array)
      # expect(header).to eq([%w(a b)])
    end

    it 'should auto RST_STREAM promises against locally-RST stream' do
      s = @client.new_stream
      s.send HEADERS.deep_dup
      s.close

      allow(@client).to receive(:send)
      expect(@client).to receive(:send) do |frame|
        expect(frame[:type]).to eq :rst_stream
        expect(frame[:stream]).to eq 2
      end

      @client << set_stream_id(f.generate(PUSH_PROMISE.dup), s.id)
    end
  end
end
