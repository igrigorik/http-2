require "helper"

describe HTTP2::Stream do
  before(:each) do
    @client = Client.new
    @stream = @client.new_stream
  end

  context "stream states" do
    it "should initiliaze all streams to IDLE" do
      @stream.state.should eq :idle
    end

    it "should set custom stream priority" do
      stream = @client.new_stream(weight: 3, dependency: 2, exclusive: true)
      stream.weight.should eq 3
    end

    context "reserved (local)" do
      before(:each) { @stream.send PUSH_PROMISE }

      it "should transition on sent PUSH_PROMISE" do
        @stream.state.should eq :reserved_local
      end

      it "should allow HEADERS to be sent" do
        expect { @stream.send HEADERS }.to_not raise_error
      end

      it "should raise error if sending invalid frames" do
        (FRAME_TYPES - [HEADERS, RST_STREAM]).each do |type|
          expect { @stream.dup.send type }.to raise_error StreamError
        end
      end

      it "should raise error on receipt of invalid frames" do
        (FRAME_TYPES - [PRIORITY, RST_STREAM]).each do |type|
          expect { @stream.dup.receive type }.to raise_error StreamError
        end
      end

      it "should transition to half closed (remote) on sent HEADERS" do
        @stream.send HEADERS
        @stream.state.should eq :half_closed_remote
      end

      it "should transition to closed on sent RST_STREAM" do
        @stream.close
        @stream.state.should eq :closed
      end

      it "should transition to closed on received RST_STREAM" do
        @stream.receive RST_STREAM
        @stream.state.should eq :closed
      end

      it "should reprioritize stream on PRIORITY" do
        expect { @stream.receive PRIORITY }.to_not raise_error
        @stream.weight.should eq 20
      end
    end

    context "reserved (remote)" do
      before(:each) { @stream.receive PUSH_PROMISE }

      it "should transition on received PUSH_PROMISE" do
        @stream.state.should eq :reserved_remote
      end

      it "should raise error if sending invalid frames" do
        (FRAME_TYPES - [PRIORITY, RST_STREAM]).each do |type|
          expect { @stream.dup.send type }.to raise_error StreamError
        end
      end

      it "should raise error on receipt of invalid frames" do
        (FRAME_TYPES - [HEADERS, RST_STREAM]).each do |type|
          expect { @stream.dup.receive type }.to raise_error StreamError
        end
      end

      it "should transition to half closed (local) on received HEADERS" do
        @stream.receive HEADERS
        @stream.state.should eq :half_closed_local
      end

      it "should transition to closed on sent RST_STREAM" do
        @stream.close
        @stream.state.should eq :closed
      end

      it "should transition to closed on received RST_STREAM" do
        @stream.receive RST_STREAM
        @stream.state.should eq :closed
      end

      it "should reprioritize stream on PRIORITY" do
        expect { @stream.send PRIORITY }.to_not raise_error
        @stream.weight.should eq 20
      end
    end

    context "open" do
      before(:each) { @stream.receive HEADERS }

      it "should allow any valid frames types to be sent" do
        (FRAME_TYPES - [PING, GOAWAY, SETTINGS]).each do |type|
          expect { @stream.dup.send type }.to_not raise_error
        end
      end

      it "should allow frames of any type to be received" do
        FRAME_TYPES.each do |type|
          expect { @stream.dup.receive type }.to_not raise_error
        end
      end

      it "should transition to half closed (local) if sending END_STREAM" do
        [DATA, HEADERS].each do |frame|
          s, f = @stream.dup, frame.dup
          f[:flags] = [:end_stream]

          s.send f
          s.state.should eq :half_closed_local
        end
      end

      it "should transition to half closed (remote) if receiving END_STREAM" do
        [DATA, HEADERS].each do |frame|
          s, f = @stream.dup, frame.dup
          f[:flags] = [:end_stream]

          s.receive f
          s.state.should eq :half_closed_remote
        end
      end

      it "should transition to half closed if remote opened with END_STREAM" do
        s = @client.new_stream
        hclose = HEADERS.dup
        hclose[:flags] = [:end_stream]

        s.receive hclose
        s.state.should eq :half_closed_remote
      end

      it "should transition to half closed if local opened with END_STREAM" do
        s = @client.new_stream
        hclose = HEADERS.dup
        hclose[:flags] = [:end_stream]

        s.send hclose
        s.state.should eq :half_closed_local
      end

      it "should transition to closed if sending RST_STREAM" do
        @stream.close
        @stream.state.should eq :closed
      end

      it "should transition to closed if receiving RST_STREAM" do
        @stream.receive RST_STREAM
        @stream.state.should eq :closed
      end

      it "should emit :active on open transition" do
        openp, openr = false, false
        sp = @client.new_stream
        sr = @client.new_stream
        sp.on(:active) { openp = true }
        sr.on(:active) { openr = true }

        sp.receive HEADERS
        sr.send HEADERS

        openp.should be_truthy
        openr.should be_truthy
      end

      it "should not emit :active on transition from open" do
        order, stream = [], @client.new_stream

        stream.on(:active) { order << :active }
        stream.on(:half_close) { order << :half_close }
        stream.on(:close)  { order << :close }

        req = HEADERS.dup
        req[:flags] = [:end_headers]

        stream.send req
        stream.send DATA
        order.should eq [:active, :half_close]
      end

      it "should emit :close on close transition" do
        closep, closer = false, false
        sp, sr = @stream.dup, @stream.dup

        sp.on(:close) { closep = true }
        sr.on(:close) { closer = true }

        sp.receive RST_STREAM
        sr.close

        closep.should be_truthy
        closer.should be_truthy
      end

      it "should emit :close after frame is processed" do
        order, stream = [], @client.new_stream

        stream.on(:active) { order << :active }
        stream.on(:data)   { order << :data }
        stream.on(:half_close) { order << :half_close }
        stream.on(:close)  { order << :close }

        req = HEADERS.dup
        req[:flags] = [:end_stream, :end_headers]

        stream.send req
        stream.receive HEADERS
        stream.receive DATA

        order.should eq [:active, :half_close, :data, :close]
      end

      it "should emit :close with reason" do
        reason = nil
        @stream.on(:close) {|r| reason = r }
        @stream.receive RST_STREAM
        reason.should_not be_nil
      end
    end

    context "half closed (local)" do
      before(:each) { @stream.send HEADERS_END_STREAM }

      it "should raise error on attempt to send frames" do
        (FRAME_TYPES - [PRIORITY, RST_STREAM]).each do |frame|
          expect { @stream.dup.send frame }.to raise_error StreamError
        end
      end

      it "should transition to closed on receipt of END_STREAM flag" do
        [DATA, HEADERS, CONTINUATION].each do |frame|
          s, f = @stream.dup, frame.dup
          f[:flags] = [:end_stream]

          s.receive f
          s.state.should eq :closed
        end
      end

      it "should transition to closed on receipt of RST_STREAM frame" do
        @stream.receive RST_STREAM
        @stream.state.should eq :closed
      end

      it "should transition to closed if RST_STREAM frame is sent" do
        @stream.send RST_STREAM
        @stream.state.should eq :closed
      end

      it "should ignore received WINDOW_UPDATE, PRIORITY frames" do
        expect { @stream.receive WINDOW_UPDATE }.to_not raise_error
        expect { @stream.receive PRIORITY }.to_not raise_error
        @stream.state.should eq :half_closed_local
      end

      it "should reprioritize stream on PRIORITY" do
        expect { @stream.send PRIORITY }.to_not raise_error
        @stream.weight.should eq 20
      end

      it "should emit :half_close event on transition" do
        order = []
        stream = @client.new_stream
        stream.on(:active) { order << :active }
        stream.on(:half_close) { order << :half_close }

        req = HEADERS.dup
        req[:flags] = [:end_stream, :end_headers]

        stream.send req
        order.should eq [:active, :half_close]
      end

      it "should emit :close event on transition to closed" do
        closed = false
        @stream.on(:close) { closed = true }
        @stream.receive RST_STREAM

        @stream.state.should eq :closed
        closed.should be_truthy
      end
    end

    context "half closed (remote)" do
      before(:each) { @stream.receive HEADERS_END_STREAM }

      it "should raise STREAM_CLOSED error on reciept of frames" do
        (FRAME_TYPES - [PRIORITY, RST_STREAM, WINDOW_UPDATE]).each do |frame|
          expect {
            @stream.dup.receive frame
          }.to raise_error(StreamClosed)
        end
      end

      it "should transition to closed if END_STREAM flag is sent" do
        [DATA, HEADERS].each do |frame|
          s, f = @stream.dup, frame.dup
          f[:flags] = [:end_stream]

          s.on(:close) { s.state.should eq :closed }
          s.send f
          s.state.should eq :closed
        end
      end

      it "should transition to closed if RST_STREAM is sent" do
        @stream.close
        @stream.state.should eq :closed
      end

      it "should transition to closed on reciept of RST_STREAM frame" do
        @stream.receive RST_STREAM
        @stream.state.should eq :closed
      end

      it "should ignore received WINDOW_UPDATE frames" do
        expect { @stream.receive WINDOW_UPDATE }.to_not raise_error
        @stream.state.should eq :half_closed_remote
      end

      it "should reprioritize stream on PRIORITY" do
        expect { @stream.receive PRIORITY }.to_not raise_error
        @stream.weight.should eq 20
      end

      it "should emit :half_close event on transition" do
        order = []
        stream = @client.new_stream
        stream.on(:active) { order << :active }
        stream.on(:half_close) { order << :half_close }

        req = HEADERS.dup
        req[:flags] = [:end_stream, :end_headers]

        stream.receive req
        order.should eq [:active, :half_close]
      end

      it "should emit :close event on close transition" do
        closed = false
        @stream.on(:close) { closed = true }
        @stream.close

        @stream.state.should eq :closed
        closed.should be_truthy
      end
    end

    context "closed" do
      context "remote closed stream" do
        before(:each) do
          @stream.send HEADERS_END_STREAM     # half closed local
          @stream.receive HEADERS_END_STREAM  # closed by remote
        end

        it "should raise STREAM_CLOSED on attempt to send frames" do
          (FRAME_TYPES - [PRIORITY, RST_STREAM]).each do |frame|
            expect {
              @stream.dup.send frame
            }.to raise_error(StreamClosed)
          end
        end

        it "should raise STREAM_CLOSED on receipt of frame" do
          (FRAME_TYPES - [PRIORITY, RST_STREAM, WINDOW_UPDATE]).each do |frame|
            expect {
              @stream.dup.receive frame
            }.to raise_error(StreamClosed)
          end
        end

        it "should allow PRIORITY, RST_STREAM to be sent" do
          expect { @stream.send PRIORITY }.to_not raise_error
          expect { @stream.send RST_STREAM }.to_not raise_error
        end

        it "should allow PRIORITY, RST_STREAM to be received" do
          expect { @stream.receive PRIORITY }.to_not raise_error
          expect { @stream.receive RST_STREAM }.to_not raise_error
        end

        it "should reprioritize stream on PRIORITY" do
          expect { @stream.receive PRIORITY }.to_not raise_error
          @stream.weight.should eq 20
        end

      end

      context "local closed via RST_STREAM frame" do
        before(:each) do
          @stream.send HEADERS     # open
          @stream.send RST_STREAM  # closed by local
        end

        it "should ignore received frames" do
          (FRAME_TYPES - [PUSH_PROMISE]).each do |frame|
            expect {
              cb = []
              @stream.on(:data) { cb << :data }
              @stream.on(:headers) { cb << :headers}
              @stream.dup.receive frame
              cb.should be_empty
            }.to_not raise_error
          end
        end

        #it "should transition to reserved remote on PUSH_PROMISE" do
          # An endpoint might receive a PUSH_PROMISE frame after it sends
          # RST_STREAM.  PUSH_PROMISE causes a stream to become "reserved".
          # ...
          # We're auto RST'ing PUSH streams in connection class, hence
          # skipping this transition for now.
        #end

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

  context "flow control" do
    it "should initialize to default flow control window" do
      @stream.remote_window.should eq DEFAULT_FLOW_WINDOW
    end

    it "should update window size on DATA frames only" do
      @stream.send HEADERS # go to open
      @stream.remote_window.should eq DEFAULT_FLOW_WINDOW

      (FRAME_TYPES - [DATA,PING,GOAWAY,SETTINGS]).each do |frame|
        s = @stream.dup
        s.send frame
        s.remote_window.should eq DEFAULT_FLOW_WINDOW
      end

      @stream.send DATA
      @stream.remote_window.should eq DEFAULT_FLOW_WINDOW - DATA[:payload].bytesize
    end

    it "should update window size on receipt of WINDOW_UPDATE" do
      @stream.send HEADERS
      @stream.send DATA
      @stream.receive WINDOW_UPDATE

      @stream.remote_window.should eq (
        DEFAULT_FLOW_WINDOW - DATA[:payload].bytesize + WINDOW_UPDATE[:increment]
      )
    end

    it "should observe session flow control" do
      settings, data = SETTINGS.dup, DATA.dup
      settings[:payload] = [[:settings_initial_window_size, 1000]]
      settings[:stream] = 0

      framer = Framer.new
      @client << framer.generate(settings)

      s1 = @client.new_stream
      s1.send HEADERS
      s1.send data.merge({payload: "x" * 900, flags: []})
      s1.remote_window.should eq 100

      s1.send data.merge({payload: "x" * 200})
      s1.remote_window.should eq 0
      s1.buffered_amount.should eq 100

      @client << framer.generate(WINDOW_UPDATE.merge({
        stream: s1.id, increment: 1000
      }))
      s1.buffered_amount.should eq 0
      s1.remote_window.should eq 900
    end
  end

  context "client API" do
    it ".reprioritize should emit PRIORITY frame" do
      @stream.should_receive(:send) do |frame|
        frame[:type].should eq :priority
        frame[:weight].should eq 30
      end

      @stream.reprioritize weight: 30
    end

    it ".reprioritize should raise error if invoked by server" do
      srv = Server.new
      stream = srv.new_stream

      expect { stream.reprioritize(weight: 10) }.to raise_error(StreamError)
    end

    it ".headers should emit HEADERS frames" do
      payload = {
        ':method' => 'GET',
        ':scheme' => 'http',
        ':host'   => 'www.example.org',
        ':path'   => '/resource',
        'custom'  => 'value'
      }

      @stream.should_receive(:send) do |frame|
        frame[:type].should eq :headers
        frame[:payload].should eq payload.to_a
        frame[:flags].should eq [:end_headers]
      end

      @stream.headers(payload, end_stream: false, end_headers: true)
    end

    it ".data should emit DATA frames" do
      @stream.should_receive(:send) do |frame|
        frame[:type].should eq :data
        frame[:payload].should eq "text"
        frame[:flags].should be_empty
      end
      @stream.data("text", end_stream: false)

      @stream.should_receive(:send) do |frame|
        frame[:flags].should eq [:end_stream]
      end
      @stream.data("text")
    end

    it ".data should split large DATA frames" do
      data = "x" * 16384 * 2

      @stream.stub(:send)
      @stream.should_receive(:send).exactly(3).times
      @stream.data(data + "x")
    end

    it ".cancel should reset stream with cancel error code" do
      @stream.should_receive(:send) do |frame|
        frame[:type].should eq :rst_stream
        frame[:error].should eq :cancel
      end

      @stream.cancel
    end

    it ".refuse should reset stream with refused stream error code" do
      @stream.should_receive(:send) do |frame|
        frame[:type].should eq :rst_stream
        frame[:error].should eq :refused_stream
      end

      @stream.refuse
    end
  end

  context "server API" do
    before(:each) do
      @srv = Server.new
      @frm = Framer.new

      @client.on(:frame) {|bytes| @srv << bytes }
      @client_stream = @client.new_stream
    end

    it "should emit received headers via on(:headers)" do
      headers, recv = [["header", "value"]], nil
      @srv.on(:stream) do |stream|
        stream.on(:headers) {|h| recv = h}
      end

      @client_stream.headers(headers)
      recv.should eq headers
    end

    it "should emit received payload via on(:data)" do
      payload, recv = "some-payload", nil
      @srv.on(:stream) do |stream|
        stream.on(:data) do |recv|
          recv.should eq payload
        end
      end

      @client_stream.headers({"key" => "value"})
      @client_stream.data(payload)
    end

    it "should emit received priority parameters via on(:priority)" do
      new_weight, new_dependency = 15, @client_stream.id + 2
      callback_called = false
      @srv.on(:stream) do |stream|
        stream.on(:priority) do |pri|
          callback_called = true
          pri.is_a?(Hash).should be
          pri[:weight].should eq new_weight
          pri[:dependency].should eq new_dependency
        end
      end

      @client_stream.headers({"key" => "value"})
      @client_stream.reprioritize(weight: new_weight, dependency: new_dependency)
      callback_called.should be
    end

    context "push" do
      before(:each) do
        @srv.on(:frame)  {|bytes| @client << bytes }
        @srv.on(:stream) do |stream|
          @server_stream = stream
        end

        @client_stream.headers({"key" => "value"})
      end

      it ".promise should emit server initiated stream" do
        push = nil
        @server_stream.promise({"key" => "val"}) { |pstream| push = pstream }
        push.id.should eq 2
      end

      it ".promise push stream should have parent stream" do
        push = nil
        @server_stream.promise({"key" => "val"}) { |pstream| push = pstream }

        push.state.should eq :reserved_local
        push.parent.id.should eq @server_stream.id
      end

      context "stream states" do
        it "server: active > half close > close" do
          order = []
          @server_stream.promise({"key" => "val"}) do |push|
            stream = push

            push.state.should eq :reserved_local
            order << :reserved

            push.on(:active)    { order << :active }
            push.on(:half_close){ order << :half_close }
            push.on(:close)     { order << :close }

            push.headers({"key2" => "val2"})
            push.send DATA.merge({stream: stream.id})
          end

          order.should eq [:reserved, :active, :half_close, :close]
        end

        it "client: headers > active > headers > .. > data > close" do
          order, headers = [], []
          @client.on(:promise) do |push|
            order << :reserved

            push.on(:active)    { order << :active }
            push.on(:data)      { order << :data }
            push.on(:half_close){ order << :half_close }
            push.on(:close)     { order << :close }

            push.on(:headers) do |h|
              order << :headers
              headers += h
            end

            push.id.should be_even
          end

          @server_stream.promise({"key" => "val"}) do |push|
            push.headers("key2" => "val2")
            push.data("somedata")
          end

          headers.should eq([["key", "val"], ["key2", "val2"]])
          order.should eq [:reserved, :headers, :active, :headers,
                           :half_close, :data, :close]
        end
      end

    end
  end
end
