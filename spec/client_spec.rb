# frozen_string_literal: true

require "helper"
require "shared_examples/connection"

RSpec.describe HTTP2Next::Client do
  include FrameHelpers

  let(:f) { Framer.new }
  let(:client) do
    client = Client.new
    client << f.generate(settings_frame)
    client
  end

  it_behaves_like "a connection" do
    let(:connected_conn) { client }
  end

  context "initialization and settings" do
    let(:client) { Client.new }
    it "should raise error if first frame is not settings" do
      (frame_types - [settings_frame]).each do |frame|
        conn = Client.new
        expect { conn << f.generate(frame) }.to raise_error(ProtocolError)
        expect(conn).to be_closed
      end
    end

    it "should not raise error if first frame is SETTINGS" do
      expect { client << f.generate(settings_frame) }.to_not raise_error
      expect(client.state).to eq :connected
      expect(client).to_not be_closed
    end

    it "should raise error if SETTINGS stream != 0" do
      frame = set_stream_id(f.generate(settings_frame), 0x1)
      expect { client << frame }.to raise_error(ProtocolError)
    end

    it "should return odd stream IDs" do
      expect(client.new_stream.id).not_to be_even
    end

    it "should emit connection header and SETTINGS on new client connection" do
      frames = []
      client.on(:frame) { |bytes| frames << bytes }
      client.ping("12345678")

      expect(frames[0]).to eq CONNECTION_PREFACE_MAGIC
      expect(f.parse(frames[1])[:type]).to eq :settings
    end

    it "should initialize client with custom connection settings" do
      frames = []

      client = Client.new(settings_max_concurrent_streams: 200)
      client.on(:frame) { |bytes| frames << bytes }
      client.ping("12345678")

      frame = f.parse(frames[1])
      expect(frame[:type]).to eq :settings
      expect(frame[:payload]).to include([:settings_max_concurrent_streams, 200])
    end

    it "should initialize client when receiving server settings before sending ack" do
      frames = []
      client.on(:frame) { |bytes| frames << bytes }
      client << f.generate(settings_frame)

      expect(frames[0]).to eq CONNECTION_PREFACE_MAGIC
      expect(f.parse(frames[1])[:type]).to eq :settings
      ack_frame = f.parse(frames[2])
      expect(ack_frame[:type]).to eq :settings
      expect(ack_frame[:flags]).to include(:ack)
    end
  end

  context "settings synchronization" do
    let(:client) { Client.new }
    it "should reflect outgoing settings when ack is received" do
      expect(client.local_settings[:settings_header_table_size]).to eq 4096
      client.settings(settings_header_table_size: 256)
      expect(client.local_settings[:settings_header_table_size]).to eq 4096

      ack = { type: :settings, stream: 0, payload: [], flags: [:ack] }
      client << f.generate(ack)

      expect(client.local_settings[:settings_header_table_size]).to eq 256
    end
  end

  context "upgrade" do
    it "fails when client has already created streams" do
      client.new_stream
      expect { client.upgrade }.to raise_error(HTTP2Next::Error::ProtocolError)
    end

    it "sends the preface" do
      expect(client).to receive(:send_connection_preface)
      client.upgrade
    end

    it "initializes the first stream in the half-closed state" do
      stream = client.upgrade
      expect(stream.state).to be(:half_closed_local)
    end
  end

  context "push" do
    it "should disallow client initiated push" do
      expect do
        client.promise({}) {}
      end.to raise_error(NoMethodError)
    end

    it "should raise error on PUSH_PROMISE against stream 0" do
      expect do
        client << set_stream_id(f.generate(push_promise_frame), 0)
      end.to raise_error(ProtocolError)
    end

    it "should raise error on PUSH_PROMISE against bogus stream" do
      expect do
        client << set_stream_id(f.generate(push_promise_frame), 31_415)
      end.to raise_error(ProtocolError)
    end

    it "should raise error on PUSH_PROMISE against non-idle stream" do
      expect do
        s = client.new_stream
        s.send headers_frame

        client << set_stream_id(f.generate(push_promise_frame), s.id)
        client << set_stream_id(f.generate(push_promise_frame), s.id)
      end.to raise_error(ProtocolError)
    end

    it "should emit stream object for received PUSH_PROMISE" do
      s = client.new_stream
      s.send headers_frame

      promise = nil
      client.on(:promise) { |stream| promise = stream }
      client << set_stream_id(f.generate(push_promise_frame), s.id)

      expect(promise.id).to eq 2
      expect(promise.state).to eq :reserved_remote
    end

    it "should emit promise headers for received PUSH_PROMISE" do
      header = nil
      s = client.new_stream
      s.send headers_frame

      client.on(:promise) do |stream|
        stream.on(:promise_headers) do |h|
          header = h
        end
      end
      client << set_stream_id(f.generate(push_promise_frame), s.id)

      expect(header).to be_a(Array)
      # expect(header).to eq([%w(a b)])
    end

    it "should auto RST_STREAM promises against locally-RST stream" do
      s = client.new_stream
      s.send headers_frame
      s.close

      allow(client).to receive(:send)
      expect(client).to receive(:send) do |frame|
        expect(frame[:type]).to eq :rst_stream
        expect(frame[:stream]).to eq 2
      end

      client << set_stream_id(f.generate(push_promise_frame), s.id)
    end
  end

  context "alt-svc" do
    context "received in the connection" do
      it "should emit :altsvc when receiving one" do
        client << f.generate(settings_frame)
        frame = nil
        client.on(:altsvc) do |f|
          frame = f
        end
        client << f.generate(altsvc_frame)
        expect(frame).to be_a(Hash)
      end
      it "should not emit :altsvc when the frame when contains no host" do
        client << f.generate(settings_frame)
        frame = nil
        client.on(:altsvc) do |f|
          frame = f
        end

        client << f.generate(altsvc_frame.merge(origin: nil))
        expect(frame).to be_nil
      end
    end
    context "received in a stream" do
      it "should emit :altsvc" do
        s = client.new_stream
        s.send headers_frame
        s.close

        frame = nil
        s.on(:altsvc) { |f| frame = f }

        client << set_stream_id(f.generate(altsvc_frame.merge(origin: nil)), s.id)

        expect(frame).to be_a(Hash)
      end
      it "should not emit :alt_svc when the frame when contains a origin" do
        s = client.new_stream
        s.send headers_frame
        s.close

        frame = nil
        s.on(:altsvc) { |f| frame = f }

        client << set_stream_id(f.generate(altsvc_frame), s.id)

        expect(frame).to be_nil
      end
    end
  end

  context "origin" do
    let(:orig_frame) { origin_frame.merge(payload: %w[https://www.google.com https://www.youtube.com]) }
    context "received in the connection" do
      it "should emit :origin when receiving one" do
        client << f.generate(settings_frame)
        origins = []
        client.on(:origin) do |origin|
          origins << origin
        end
        client << f.generate(orig_frame)
        expect(origins).to include("https://www.google.com")
        expect(origins).to include("https://www.youtube.com")
      end
      context "initialized as h2c" do
        it "should be ignored" do
          client.upgrade
          origins = []
          client.on(:origin) do |origin|
            origins << origin
          end
          client << f.generate(orig_frame)
          expect(origins).to be_empty
        end
      end
      context "when receiving a reserved flag" do
        let(:orig_frame) { origin_frame.merge(flags: [:reserved]) }
        it "should be ignored" do
          client << f.generate(settings_frame)
          origins = []
          client.on(:origin) do |origin|
            origins << origin
          end
          client << f.generate(orig_frame)
          expect(origins).to be_empty
        end
      end
    end
    context "received in a stream" do
      it "should be ignored" do
        s = client.new_stream
        s.send headers_frame
        s.close

        expect do
          client << set_stream_id(f.generate(orig_frame), s.id)
        end.not_to raise_error
      end
    end
  end

  context "connection management" do
    let(:conn) { Client.new }
    it "should send GOAWAY frame on connection error" do
      stream = conn.new_stream

      expect(conn).to receive(:encode) do |frame|
        expect(frame[:type]).to eq :settings
        [frame]
      end
      expect(conn).to receive(:encode) do |frame|
        expect(frame[:type]).to eq :goaway
        expect(frame[:last_stream]).to eq stream.id
        expect(frame[:error]).to eq :protocol_error
        [frame]
      end

      expect { conn << f.generate(data_frame) }.to raise_error(ProtocolError)
    end
  end

  context "stream management" do
    it "should process connection management frames after GOAWAY" do
      stream = client.new_stream
      stream.send headers_frame
      client << f.generate(goaway_frame)
      client << f.generate(push_promise_frame)
      expect(client.active_stream_count).to eq 1
    end
  end

  context "framing" do
    it "should buffer incomplete frames" do
      frame = f.generate(window_update_frame.merge(stream: 0, increment: 1000))
      client << frame
      expect(client.remote_window).to eq DEFAULT_FLOW_WINDOW + 1000

      client << frame.slice!(0, 1)
      client << frame
      expect(client.remote_window).to eq DEFAULT_FLOW_WINDOW + 2000
    end

    it "should decompress header blocks regardless of stream state" do
      req_headers = [
        %w[:status 200],
        %w[x-my-header first]
      ]

      cc = Compressor.new
      headers = headers_frame.merge(stream: 2)
      headers[:payload] = cc.encode(req_headers)

      client.on(:stream) do |stream|
        expect(stream).to receive(:<<) do |frame|
          expect(frame[:payload]).to eq req_headers
        end
      end

      client << f.generate(headers)
    end

    it "should decode non-contiguous header blocks" do
      req_headers = [
        %w[:status 200],
        %w[x-my-header first]
      ]

      cc = Compressor.new
      h1 = headers_frame
      h2 = continuation_frame

      # Header block fragment might not complete for decompression
      payload = cc.encode(req_headers)
      h1[:payload] = payload.slice!(0, payload.size / 2) # first half
      h1[:stream] = 2
      h1[:flags] = []

      h2[:payload] = payload # the remaining
      h2[:stream] = 2

      client.on(:stream) do |stream|
        expect(stream).to receive(:<<) do |frame|
          expect(frame[:payload]).to eq req_headers
        end
      end

      client << f.generate(h1)
      client << f.generate(h2)
    end
  end

  context "API" do
    it ".goaway should generate GOAWAY frame with last processed stream ID" do
      stream = client.new_stream
      stream.send headers_frame

      expect(client).to receive(:send) do |frame|
        expect(frame[:type]).to eq :goaway
        expect(frame[:last_stream]).to eq 1
        expect(frame[:error]).to eq :internal_error
        expect(frame[:payload]).to eq "payload"
      end

      client.goaway(:internal_error, "payload")
    end
  end

  context ".settings_header" do
    it "encodes the settings frame in base64" do
      settings_header = described_class.settings_header(settings_frame[:payload])
      expect(f.generate(settings_frame)).to end_with(Base64.urlsafe_decode64(settings_header))
    end
  end
end
