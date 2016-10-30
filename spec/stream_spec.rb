require 'helper'

RSpec.describe HTTP2::Stream do
  before(:each) do
    @client = Client.new
    @stream = @client.new_stream
  end

  context 'stream states' do
    it 'should initiliaze all streams to IDLE' do
      expect(@stream.state).to eq :idle
    end

    it 'should set custom stream priority' do
      stream = @client.new_stream(weight: 3, dependency: 2, exclusive: true)
      expect(stream.weight).to eq 3
    end

    context 'idle' do
      it 'should transition to open on sent HEADERS' do
        @stream.send HEADERS.deep_dup
        expect(@stream.state).to eq :open
      end
      it 'should transition to open on received HEADERS' do
        @stream.receive HEADERS
        expect(@stream.state).to eq :open
      end
      it 'should transition to reserved (local) on sent PUSH_PROMISE' do
        @stream.send PUSH_PROMISE.deep_dup
        expect(@stream.state).to eq :reserved_local
      end
      it 'should transition to reserved (remote) on received PUSH_PROMISE' do
        @stream.receive PUSH_PROMISE
        expect(@stream.state).to eq :reserved_remote
      end
      it 'should reprioritize stream on sent PRIORITY' do
        expect { @stream.send PRIORITY.dup }.to_not raise_error
        expect(@stream.weight).to eq 20
      end
      it 'should reprioritize stream on received PRIORITY' do
        expect { @stream.send PRIORITY.dup }.to_not raise_error
        expect(@stream.weight).to eq 20
      end
    end

    context 'reserved (local)' do
      before(:each) { @stream.send PUSH_PROMISE.deep_dup }

      it 'should transition on sent PUSH_PROMISE' do
        expect(@stream.state).to eq :reserved_local
      end

      it 'should allow HEADERS to be sent' do
        expect { @stream.send HEADERS.deep_dup }.to_not raise_error
      end

      it 'should raise error if sending invalid frames' do
        (FRAME_TYPES - [HEADERS, RST_STREAM]).each do |type|
          expect { @stream.dup.send type }.to raise_error InternalError
        end
      end

      it 'should raise error on receipt of invalid frames' do
        what_types = (FRAME_TYPES - [PRIORITY, RST_STREAM, WINDOW_UPDATE])
        what_types.each do |type|
          expect { @stream.dup.receive type }.to raise_error InternalError
        end
      end

      it 'should transition to half closed (remote) on sent HEADERS' do
        @stream.send HEADERS.deep_dup
        expect(@stream.state).to eq :half_closed_remote
      end

      it 'should transition to closed on sent RST_STREAM' do
        @stream.close
        expect(@stream.state).to eq :closed
      end

      it 'should transition to closed on received RST_STREAM' do
        @stream.receive RST_STREAM
        expect(@stream.state).to eq :closed
      end

      it 'should reprioritize stream on PRIORITY' do
        expect { @stream.receive PRIORITY }.to_not raise_error
        expect(@stream.weight).to eq 20
      end

      it 'should increment remote_window on received WINDOW_UPDATE' do
        expect { @stream.receive WINDOW_UPDATE }.to_not raise_error
        expect(@stream.remote_window).to eq DEFAULT_FLOW_WINDOW + WINDOW_UPDATE[:increment]
      end
    end

    context 'reserved (remote)' do
      before(:each) { @stream.receive PUSH_PROMISE }

      it 'should transition on received PUSH_PROMISE' do
        expect(@stream.state).to eq :reserved_remote
      end

      it 'should raise error if sending invalid frames' do
        (FRAME_TYPES - [PRIORITY, RST_STREAM, WINDOW_UPDATE]).each do |type|
          expect { @stream.dup.send type }.to raise_error InternalError
        end
      end

      it 'should raise error on receipt of invalid frames' do
        (FRAME_TYPES - [HEADERS, RST_STREAM]).each do |type|
          expect { @stream.dup.receive type }.to raise_error InternalError
        end
      end

      it 'should transition to half closed (local) on received HEADERS' do
        @stream.receive HEADERS
        expect(@stream.state).to eq :half_closed_local
      end

      it 'should transition to closed on sent RST_STREAM' do
        @stream.close
        expect(@stream.state).to eq :closed
      end

      it 'should transition to closed on received RST_STREAM' do
        @stream.receive RST_STREAM
        expect(@stream.state).to eq :closed
      end

      it 'should reprioritize stream on PRIORITY' do
        expect { @stream.send PRIORITY.dup }.to_not raise_error
        expect(@stream.weight).to eq 20
      end

      it 'should increment local_window on sent WINDOW_UPDATE' do
        expect { @stream.send WINDOW_UPDATE.dup }.to_not raise_error
        expect(@stream.local_window).to eq DEFAULT_FLOW_WINDOW + WINDOW_UPDATE[:increment]
      end
    end

    context 'open' do
      before(:each) { @stream.receive HEADERS }

      it 'should allow any valid frames types to be sent' do
        (FRAME_TYPES - [PING, GOAWAY, SETTINGS]).each do |type|
          expect { @stream.dup.send type.deep_dup }.to_not raise_error
        end
      end

      it 'should allow frames of any type to be received' do
        FRAME_TYPES.each do |type|
          expect { @stream.dup.receive type }.to_not raise_error
        end
      end

      it 'should transition to half closed (local) if sending END_STREAM' do
        [DATA, HEADERS].each do |frame|
          s, f = @stream.dup, frame.deep_dup
          f[:flags] = [:end_stream]

          s.send f
          expect(s.state).to eq :half_closed_local
        end
      end

      it 'should transition to half closed (remote) if receiving END_STREAM' do
        [DATA, HEADERS].each do |frame|
          s, f = @stream.dup, frame.dup
          f[:flags] = [:end_stream]

          s.receive f
          expect(s.state).to eq :half_closed_remote
        end
      end

      it 'should transition to half closed if remote opened with END_STREAM' do
        s = @client.new_stream
        hclose = HEADERS.dup
        hclose[:flags] = [:end_stream]

        s.receive hclose
        expect(s.state).to eq :half_closed_remote
      end

      it 'should transition to half closed if local opened with END_STREAM' do
        s = @client.new_stream
        hclose = HEADERS.deep_dup
        hclose[:flags] = [:end_stream]

        s.send hclose
        expect(s.state).to eq :half_closed_local
      end

      it 'should transition to closed if sending RST_STREAM' do
        @stream.close
        expect(@stream.state).to eq :closed
      end

      it 'should transition to closed if receiving RST_STREAM' do
        @stream.receive RST_STREAM
        expect(@stream.state).to eq :closed
      end

      it 'should emit :active on open transition' do
        openp, openr = false, false
        sp = @client.new_stream
        sr = @client.new_stream
        sp.on(:active) { openp = true }
        sr.on(:active) { openr = true }

        sp.receive HEADERS
        sr.send HEADERS.deep_dup

        expect(openp).to be_truthy
        expect(openr).to be_truthy
      end

      it 'should not emit :active on transition from open' do
        order, stream = [], @client.new_stream

        stream.on(:active) { order << :active }
        stream.on(:half_close) { order << :half_close }
        stream.on(:close)  { order << :close }

        req = HEADERS.deep_dup
        req[:flags] = [:end_headers]

        stream.send req
        stream.send DATA.dup
        expect(order).to eq [:active, :half_close]
      end

      it 'should emit :close on close transition' do
        closep, closer = false, false
        sp, sr = @stream.dup, @stream.dup

        sp.on(:close) { closep = true }
        sr.on(:close) { closer = true }

        sp.receive RST_STREAM
        sr.close

        expect(closep).to be_truthy
        expect(closer).to be_truthy
      end

      it 'should emit :close after frame is processed' do
        order, stream = [], @client.new_stream

        stream.on(:active) { order << :active }
        stream.on(:data)   { order << :data }
        stream.on(:half_close) { order << :half_close }
        stream.on(:close)  { order << :close }

        req = HEADERS.deep_dup
        req[:flags] = [:end_stream, :end_headers]

        stream.send req
        stream.receive HEADERS
        stream.receive DATA

        expect(order).to eq [:active, :half_close, :data, :close]
      end

      it 'should emit :close with reason' do
        reason = nil
        @stream.on(:close) { |r| reason = r }
        @stream.receive RST_STREAM
        expect(reason).not_to be_nil
      end

      it 'should reprioritize stream on sent PRIORITY' do
        expect { @stream.send PRIORITY.dup }.to_not raise_error
        expect(@stream.weight).to eq 20
      end
      it 'should reprioritize stream on received PRIORITY' do
        expect { @stream.receive PRIORITY }.to_not raise_error
        expect(@stream.weight).to eq 20
      end
    end

    context 'half closed (local)' do
      before(:each) { @stream.send HEADERS_END_STREAM.deep_dup }

      it 'should raise error on attempt to send invalid frames' do
        (FRAME_TYPES - [PRIORITY, RST_STREAM, WINDOW_UPDATE]).each do |frame|
          expect { @stream.dup.send frame }.to raise_error InternalError
        end
      end

      it 'should transition to closed on receipt of END_STREAM flag' do
        [DATA, HEADERS, CONTINUATION].each do |frame|
          s, f = @stream.dup, frame.dup
          f[:flags] = [:end_stream]

          s.receive f
          expect(s.state).to eq :closed
        end
      end

      it 'should transition to closed on receipt of RST_STREAM frame' do
        @stream.receive RST_STREAM
        expect(@stream.state).to eq :closed
      end

      it 'should transition to closed if RST_STREAM frame is sent' do
        @stream.send RST_STREAM.deep_dup
        expect(@stream.state).to eq :closed
      end

      it 'should ignore received WINDOW_UPDATE frames' do
        expect { @stream.receive WINDOW_UPDATE }.to_not raise_error
        expect(@stream.state).to eq :half_closed_local
      end

      it 'should ignore received PRIORITY frames' do
        expect { @stream.receive PRIORITY }.to_not raise_error
        expect(@stream.state).to eq :half_closed_local
      end

      it 'should reprioritize stream on sent PRIORITY' do
        expect { @stream.send PRIORITY.dup }.to_not raise_error
        expect(@stream.weight).to eq 20
      end

      it 'should reprioritize stream (and decendants) on received PRIORITY' do
        expect { @stream.receive PRIORITY }.to_not raise_error
        expect(@stream.weight).to eq 20
      end

      it 'should increment local_window on sent WINDOW_UPDATE' do
        expect { @stream.send WINDOW_UPDATE.dup }.to_not raise_error
        expect(@stream.local_window).to eq DEFAULT_FLOW_WINDOW + WINDOW_UPDATE[:increment]
      end

      it 'should emit :half_close event on transition' do
        order = []
        stream = @client.new_stream
        stream.on(:active) { order << :active }
        stream.on(:half_close) { order << :half_close }

        req = HEADERS.deep_dup
        req[:flags] = [:end_stream, :end_headers]

        stream.send req
        expect(order).to eq [:active, :half_close]
      end

      it 'should emit :close event on transition to closed' do
        closed = false
        @stream.on(:close) { closed = true }
        @stream.receive RST_STREAM

        expect(@stream.state).to eq :closed
        expect(closed).to be_truthy
      end
    end

    context 'half closed (remote)' do
      before(:each) { @stream.receive HEADERS_END_STREAM }

      it 'should raise STREAM_CLOSED error on reciept of frames' do
        (FRAME_TYPES - [PRIORITY, RST_STREAM, WINDOW_UPDATE]).each do |frame|
          expect do
            @stream.dup.receive frame
          end.to raise_error(StreamClosed)
        end
      end

      it 'should transition to closed if END_STREAM flag is sent' do
        [DATA, HEADERS].each do |frame|
          s, f = @stream.dup, frame.deep_dup
          f[:flags] = [:end_stream]

          s.on(:close) { expect(s.state).to eq :closed }
          s.send f
          expect(s.state).to eq :closed
        end
      end

      it 'should transition to closed if RST_STREAM is sent' do
        @stream.close
        expect(@stream.state).to eq :closed
      end

      it 'should transition to closed on reciept of RST_STREAM frame' do
        @stream.receive RST_STREAM
        expect(@stream.state).to eq :closed
      end

      it 'should ignore sent WINDOW_UPDATE frames' do
        expect { @stream.send WINDOW_UPDATE.dup }.to_not raise_error
        expect(@stream.state).to eq :half_closed_remote
      end

      it 'should increment remote_window on received WINDOW_UPDATE' do
        expect { @stream.receive WINDOW_UPDATE }.to_not raise_error
        expect(@stream.remote_window).to eq DEFAULT_FLOW_WINDOW + WINDOW_UPDATE[:increment]
      end

      it 'should reprioritize stream on sent PRIORITY' do
        expect { @stream.send PRIORITY.dup }.to_not raise_error
        expect(@stream.weight).to eq 20
      end
      it 'should reprioritize stream on received PRIORITY' do
        expect { @stream.receive PRIORITY }.to_not raise_error
        expect(@stream.weight).to eq 20
      end

      it 'should emit :half_close event on transition' do
        order = []
        stream = @client.new_stream
        stream.on(:active) { order << :active }
        stream.on(:half_close) { order << :half_close }

        req = HEADERS.dup
        req[:flags] = [:end_stream, :end_headers]

        stream.receive req
        expect(order).to eq [:active, :half_close]
      end

      it 'should emit :close event on close transition' do
        closed = false
        @stream.on(:close) { closed = true }
        @stream.close

        expect(@stream.state).to eq :closed
        expect(closed).to be_truthy
      end
    end

    context 'closed' do
      context 'remote closed stream' do
        before(:each) do
          @stream.send HEADERS_END_STREAM.deep_dup     # half closed local
          @stream.receive HEADERS_END_STREAM  # closed by remote
        end

        it 'should raise STREAM_CLOSED on attempt to send frames' do
          (FRAME_TYPES - [PRIORITY, RST_STREAM]).each do |frame|
            expect do
              @stream.dup.send frame
            end.to raise_error(StreamClosed)
          end
        end

        it 'should raise STREAM_CLOSED on receipt of frame' do
          (FRAME_TYPES - [PRIORITY, RST_STREAM, WINDOW_UPDATE]).each do |frame|
            expect do
              @stream.dup.receive frame
            end.to raise_error(StreamClosed)
          end
        end

        it 'should allow PRIORITY, RST_STREAM to be sent' do
          expect { @stream.send PRIORITY.dup }.to_not raise_error
          expect { @stream.send RST_STREAM.dup }.to_not raise_error
        end

        it 'should allow PRIORITY, RST_STREAM to be received' do
          expect { @stream.receive PRIORITY }.to_not raise_error
          expect { @stream.receive RST_STREAM }.to_not raise_error
        end

        it 'should reprioritize stream on sent PRIORITY' do
          expect { @stream.send PRIORITY.dup }.to_not raise_error
          expect(@stream.weight).to eq 20
        end
        it 'should reprioritize stream on received PRIORITY' do
          expect { @stream.receive PRIORITY }.to_not raise_error
          expect(@stream.weight).to eq 20
        end

        it 'should ignore received WINDOW_UPDATE frames' do
          expect { @stream.receive WINDOW_UPDATE }.to_not raise_error
          expect(@stream.state).to eq :closed
        end
      end

      context 'local closed via RST_STREAM frame' do
        before(:each) do
          @stream.send HEADERS.deep_dup     # open
          @stream.send RST_STREAM.deep_dup  # closed by local
        end

        it 'should ignore received frames' do
          (FRAME_TYPES - [PUSH_PROMISE]).each do |frame|
            expect do
              cb = []
              @stream.on(:data) { cb << :data }
              @stream.on(:headers) { cb << :headers }
              @stream.dup.receive frame.dup
              expect(cb).to be_empty
            end.to_not raise_error
          end
        end

        # it "should transition to reserved remote on PUSH_PROMISE" do
        # An endpoint might receive a PUSH_PROMISE frame after it sends
        # RST_STREAM.  PUSH_PROMISE causes a stream to become "reserved".
        # ...
        # We're auto RST'ing PUSH streams in connection class, hence
        # skipping this transition for now.
        # end
      end

      # FIXME: Isn't this test same as "half closed (local)"?
      # context "local closed via END_STREAM flag" do
      #   before(:each) do
      #     @stream.send HEADERS  # open
      #     @stream.send DATA     # contains end_stream flag
      #   end

      #   it "should ignore received frames" do
      #     FRAME_TYPES.each do |frame|
      #       expect { @stream.dup.receive frame }.to_not raise_error
      #     end
      #   end
      # end
    end
  end # end stream states

  # TODO: add test cases to ensure on(:priority) emitted after close

  context 'flow control' do
    it 'should initialize to default flow control window' do
      expect(@stream.remote_window).to eq DEFAULT_FLOW_WINDOW
    end

    it 'should update window size on DATA frames only' do
      @stream.send HEADERS.deep_dup # go to open
      expect(@stream.remote_window).to eq DEFAULT_FLOW_WINDOW

      (FRAME_TYPES - [DATA, PING, GOAWAY, SETTINGS]).each do |frame|
        s = @stream.dup
        s.send frame.deep_dup
        expect(s.remote_window).to eq DEFAULT_FLOW_WINDOW
      end

      @stream.send DATA.dup
      expect(@stream.remote_window).to eq DEFAULT_FLOW_WINDOW - DATA[:payload].bytesize
    end

    it 'should update window size on receipt of WINDOW_UPDATE' do
      @stream.send HEADERS.deep_dup
      @stream.send DATA.dup
      @stream.receive WINDOW_UPDATE

      expect(@stream.remote_window).to eq(
        DEFAULT_FLOW_WINDOW - DATA[:payload].bytesize + WINDOW_UPDATE[:increment],
      )
    end

    it 'should observe session flow control' do
      settings, data = SETTINGS.dup, DATA.dup
      settings[:payload] = [[:settings_initial_window_size, 1000]]
      settings[:stream] = 0

      framer = Framer.new
      @client << framer.generate(settings)

      s1 = @client.new_stream
      s1.send HEADERS.deep_dup
      s1.send data.merge(payload: 'x' * 900, flags: [])
      expect(s1.remote_window).to eq 100

      s1.send data.merge(payload: 'x' * 200)
      expect(s1.remote_window).to eq 0
      expect(s1.buffered_amount).to eq 100

      @client << framer.generate(WINDOW_UPDATE.merge(stream: s1.id, increment: 1000))
      expect(s1.buffered_amount).to eq 0
      expect(s1.remote_window).to eq 900
    end

    it 'should keep track of incoming flow control' do
      data = DATA.deep_dup
      datalen = data[:payload].bytesize
      expect(@stream).to receive(:send) do |frame|
        expect(frame[:type]).to eq :window_update
        expect(frame[:increment]).to eq datalen
      end
      expect(@client).to receive(:send) do |frame|
        expect(frame[:type]).to eq :window_update
        expect(frame[:increment]).to eq datalen
      end
      @stream.receive HEADERS.deep_dup
      @stream.receive data
    end
  end

  context 'client API' do
    it '.reprioritize should emit PRIORITY frame' do
      expect(@stream).to receive(:send) do |frame|
        expect(frame[:type]).to eq :priority
        expect(frame[:weight]).to eq 30
      end

      @stream.reprioritize weight: 30
    end

    it '.reprioritize should raise error if invoked by server' do
      srv = Server.new
      stream = srv.new_stream

      expect { stream.reprioritize(weight: 10) }.to raise_error(InternalError)
    end

    it '.headers should emit HEADERS frames' do
      payload = {
        ':method' => 'GET',
        ':scheme' => 'http',
        ':host'   => 'www.example.org',
        ':path'   => '/resource',
        'custom'  => 'value',
      }

      expect(@stream).to receive(:send) do |frame|
        expect(frame[:type]).to eq :headers
        expect(frame[:payload]).to eq payload.to_a
        expect(frame[:flags]).to eq [:end_headers]
      end

      @stream.headers(payload, end_stream: false, end_headers: true)
    end

    it '.data should emit DATA frames' do
      expect(@stream).to receive(:send) do |frame|
        expect(frame[:type]).to eq :data
        expect(frame[:payload]).to eq 'text'
        expect(frame[:flags]).to be_empty
      end
      @stream.data('text', end_stream: false)

      expect(@stream).to receive(:send) do |frame|
        expect(frame[:flags]).to eq [:end_stream]
      end
      @stream.data('text')
    end

    it '.data should split large DATA frames' do
      data = 'x' * 16_384 * 2

      want = [
        { type: :data, flags: [], length: 16_384 },
        { type: :data, flags: [], length: 16_384 },
        { type: :data, flags: [:end_stream], length: 1 },
      ]
      want.each do |w|
        expect(@stream).to receive(:send) do |frame|
          expect(frame[:type]).to eq w[:type]
          expect(frame[:flags]).to eq w[:flags]
          expect(frame[:payload].bytesize).to eq w[:length]
        end
      end

      @stream.data(data + 'x')
    end

    it '.data should split large multibyte DATA frames' do
      data = '🐼' * 16_384

      want = [
        { type: :data, flags: [], length: 16_384 },
        { type: :data, flags: [], length: 16_384 },
        { type: :data, flags: [], length: 16_384 },
        { type: :data, flags: [], length: 16_384 },
        { type: :data, flags: [:end_stream], length: 1 },
      ]
      want.each do |w|
        expect(@stream).to receive(:send) do |frame|
          expect(frame[:type]).to eq w[:type]
          expect(frame[:flags]).to eq w[:flags]
          expect(frame[:payload].bytesize).to eq w[:length]
        end
      end

      @stream.data(data + 'x')
    end

    it '.cancel should reset stream with cancel error code' do
      expect(@stream).to receive(:send) do |frame|
        expect(frame[:type]).to eq :rst_stream
        expect(frame[:error]).to eq :cancel
      end

      @stream.cancel
    end

    it '.refuse should reset stream with refused stream error code' do
      expect(@stream).to receive(:send) do |frame|
        expect(frame[:type]).to eq :rst_stream
        expect(frame[:error]).to eq :refused_stream
      end

      @stream.refuse
    end

    it '.window_update should emit WINDOW_UPDATE frames' do
      expect(@stream).to receive(:send) do |frame|
        expect(frame[:type]).to eq :window_update
        expect(frame[:increment]).to eq 20
      end
      @stream.window_update(20)
    end
  end

  context 'server API' do
    before(:each) do
      @srv = Server.new
      @frm = Framer.new

      @client.on(:frame) { |bytes| @srv << bytes }
      @client_stream = @client.new_stream
    end

    it 'should emit received headers via on(:headers)' do
      headers, recv = [%w(header value)], nil
      @srv.on(:stream) do |stream|
        stream.on(:headers) { |h| recv = h }
      end

      @client_stream.headers(headers)
      expect(recv).to eq headers
    end

    it 'should emit received payload via on(:data)' do
      payload = 'some-payload'
      @srv.on(:stream) do |stream|
        stream.on(:data) do |recv|
          expect(recv).to eq payload
        end
      end

      @client_stream.headers('key' => 'value')
      @client_stream.data(payload)
    end

    it 'should emit received priority parameters via on(:priority)' do
      new_weight, new_dependency = 15, @client_stream.id + 2
      callback_called = false
      @srv.on(:stream) do |stream|
        stream.on(:priority) do |pri|
          callback_called = true
          expect(pri.is_a?(Hash)).to be
          expect(pri[:weight]).to eq new_weight
          expect(pri[:dependency]).to eq new_dependency
        end
      end

      @client_stream.headers('key' => 'value')
      @client_stream.reprioritize(weight: new_weight, dependency: new_dependency)
      expect(callback_called).to be
    end

    context 'push' do
      before(:each) do
        @srv.on(:frame)  { |bytes| @client << bytes }
        @srv.on(:stream) do |stream|
          @server_stream = stream
        end

        @client_stream.headers('key' => 'value')
      end

      it '.promise should emit server initiated stream' do
        push = nil
        @server_stream.promise('key' => 'val') { |pstream| push = pstream }
        expect(push.id).to eq 2
      end

      it '.promise push stream should have parent stream' do
        push = nil
        @server_stream.promise('key' => 'val') { |pstream| push = pstream }

        expect(push.state).to eq :reserved_local
        expect(push.parent.id).to eq @server_stream.id
      end

      context 'stream states' do
        it 'server: active > half close > close' do
          order = []
          @server_stream.promise('key' => 'val') do |push|
            stream = push

            expect(push.state).to eq :reserved_local
            order << :reserved

            push.on(:active)    { order << :active }
            push.on(:half_close) { order << :half_close }
            push.on(:close)     { order << :close }

            push.headers('key2' => 'val2')
            push.send DATA.merge(stream: stream.id)
          end

          expect(order).to eq [:reserved, :active, :half_close, :close]
        end

        it 'client: headers > active > headers > .. > data > close' do
          order, headers = [], []
          @client.on(:promise) do |push|
            order << :reserved

            push.on(:active)    { order << :active }
            push.on(:data)      { order << :data }
            push.on(:half_close) { order << :half_close }
            push.on(:close)     { order << :close }

            push.on(:headers) do |h|
              order << :headers
              headers += h
            end

            expect(push.id).to be_even
          end

          @server_stream.promise('key' => 'val') do |push|
            push.headers('key2' => 'val2')
            push.data('somedata')
          end

          expect(headers).to eq([%w(key val), %w(key2 val2)])
          expect(order).to eq [
            :reserved,
            :headers,
            :active,
            :headers,
            :half_close,
            :data,
            :close,
          ]
        end
      end
    end
  end
end
