require "helper"

describe HTTP2::Stream do
  before(:each) do
    @conn = Connection.new
    @stream = @conn.new_stream
  end

  context "stream states" do
    it "should initiliaze all streams to IDLE" do
      @stream.state.should eq :idle
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
          expect { @stream.dup.process type }.to raise_error StreamError
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
        @stream.process RST_STREAM
        @stream.state.should eq :closed
      end

      it "should reprioritize stream on PRIORITY" do
        @stream.process PRIORITY.merge({priority: 30})
        @stream.priority.should eq 30
      end
    end

    context "reserved (remote)" do
      before(:each) { @stream.process PUSH_PROMISE }

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
          expect { @stream.dup.process type }.to raise_error StreamError
        end
      end

      it "should transition to half closed (local) on received HEADERS" do
        @stream.process HEADERS
        @stream.state.should eq :half_closed_local
      end

      it "should transition to closed on sent RST_STREAM" do
        @stream.close
        @stream.state.should eq :closed
      end

      it "should transition to closed on received RST_STREAM" do
        @stream.process RST_STREAM
        @stream.state.should eq :closed
      end

      it "should reprioritize stream on PRIORITY" do
        @stream.send PRIORITY
        @stream.priority.should eq 15
      end
    end

    context "open" do
      before(:each) { @stream.process HEADERS }

      it "should allow any valid frames types to be sent" do
        (FRAME_TYPES - [PING, GOAWAY, SETTINGS]).each do |type|
          expect { @stream.dup.send type }.to_not raise_error
        end
      end

      it "should allow frames of any type to be received" do
        FRAME_TYPES.each do |type|
          expect { @stream.dup.process type }.to_not raise_error
        end
      end

      it "should transition to half closed (local) if sending END_STREAM" do
        [DATA, HEADERS, CONTINUATION].each do |frame|
          s, f = @stream.dup, frame.dup
          f[:flags] = [:end_stream]

          s.send f
          s.state.should eq :half_closed_local
        end
      end

      it "should transition to half closed (remote) if receiving END_STREAM" do
        [DATA, HEADERS, CONTINUATION].each do |frame|
          s, f = @stream.dup, frame.dup
          f[:flags] = [:end_stream]

          s.process f
          s.state.should eq :half_closed_remote
        end
      end

      it "should transition to half closed if remote opened with END_STREAM" do
        s = @conn.new_stream
        hclose = HEADERS.dup
        hclose[:flags] = [:end_stream]

        s.process hclose
        s.state.should eq :half_closed_remote
      end

      it "should transition to half closed if local opened with END_STREAM" do
        s = @conn.new_stream
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
        @stream.process RST_STREAM
        @stream.state.should eq :closed
      end

      it "should emit :active on open transition" do
        openp, openr = false, false
        sp = @conn.new_stream
        sr = @conn.new_stream
        sp.on(:active) { openp = true }
        sr.on(:active) { openr = true }

        sp.process HEADERS
        sr.send HEADERS

        openp.should be_true
        openr.should be_true
      end

      it "should emit :close on close transition" do
        closep, closer = false, false
        sp, sr = @stream.dup, @stream.dup

        sp.on(:close) { closep = true }
        sr.on(:close) { closer = true }

        sp.process RST_STREAM
        sr.close

        closep.should be_true
        closer.should be_true
      end

      it "should emit :close after frame is processed" do
        order, stream = [], @conn.new_stream

        stream.on(:active) { order << :active }
        stream.on(:data)   { order << :data }
        stream.on(:close)  { order << :close }

        req = HEADERS.dup
        req[:flags] = [:end_stream, :end_headers]

        stream.send req
        stream.process HEADERS
        stream.process DATA

        order.should eq [:active, :data, :close]
      end

      it "should emit reason with :close event" do
        reason = nil
        @stream.on(:close) {|r| reason = r }
        @stream.process RST_STREAM
        reason.should_not be_nil
      end
    end

    context "half closed (local)" do
      before(:each) { @stream.send HEADERS_END_STREAM }

      it "should raise error on attempt to send frames" do
        (FRAME_TYPES - [RST_STREAM]).each do |frame|
          expect { @stream.dup.send frame }.to raise_error StreamError
        end
      end

      it "should transition to closed on receipt of END_STREAM flag" do
        [DATA, HEADERS, CONTINUATION].each do |frame|
          s, f = @stream.dup, frame.dup
          f[:flags] = [:end_stream]

          s.process f
          s.state.should eq :closed
        end
      end

      it "should transition to closed on receipt of RST_STREAM frame" do
        @stream.process RST_STREAM
        @stream.state.should eq :closed
      end

      it "should transition to closed if RST_STREAM frame is sent" do
        @stream.send RST_STREAM
        @stream.state.should eq :closed
      end

      it "should ignore received WINDOW_UPDATE, PRIORITY frames" do
        expect { @stream.process WINDOW_UPDATE }.to_not raise_error
        expect { @stream.process PRIORITY }.to_not raise_error
        @stream.state.should eq :half_closed_local
      end

      it "should emit :close event on close transition" do
        closed = false
        @stream.on(:close) { closed = true }
        @stream.process RST_STREAM

        @stream.state.should eq :closed
        closed.should be_true
      end
    end

    context "half closed (remote)" do
      before(:each) { @stream.process HEADERS_END_STREAM }

      it "should raise STREAM_CLOSED error on reciept of frames" do
        (FRAME_TYPES - [RST_STREAM, WINDOW_UPDATE]).each do |frame|
          expect {
            @stream.dup.process frame
          }.to raise_error(StreamError, /stream closed/i)
        end
      end

      it "should transition to closed if END_STREAM flag is sent" do
        [DATA, HEADERS, CONTINUATION].each do |frame|
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
        @stream.process RST_STREAM
        @stream.state.should eq :closed
      end

      it "should ignore received WINDOW_UPDATE frames" do
        expect { @stream.process WINDOW_UPDATE }.to_not raise_error
        @stream.state.should eq :half_closed_remote
      end

      it "should emit :close event on close transition" do
        closed = false
        @stream.on(:close) { closed = true }
        @stream.close

        @stream.state.should eq :closed
        closed.should be_true
      end
    end

    context "closed" do
      context "remote closed stream" do
        before(:each) do
          @stream.send HEADERS_END_STREAM     # half closed local
          @stream.process HEADERS_END_STREAM  # closed by remote
        end

        it "should raise STREAM_CLOSED on attempt to send frames" do
          (FRAME_TYPES - [RST_STREAM]).each do |frame|
            expect {
              @stream.dup.send frame
            }.to raise_error(StreamError, /stream closed/i)
          end
        end

        it "should raise STREAM_CLOSED on receipt of frame" do
          (FRAME_TYPES - [RST_STREAM]).each do |frame|
            expect {
              @stream.dup.process frame
            }.to raise_error(StreamError, /stream closed/i)
          end
        end

        it "should allow RST_STREAM to be sent" do
          expect { @stream.send RST_STREAM }.to_not raise_error
        end

        it "should not send RST_STREAM on receipt of RST_STREAM" do
          expect { @stream.process RST_STREAM }.to_not raise_error
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
              @stream.dup.process frame
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

     context "local closed via END_STREAM flag" do
        before(:each) do
          @stream.send HEADERS  # open
          @stream.send DATA     # contains end_stream flag
        end

        it "should ignore received frames" do
          FRAME_TYPES.each do |frame|
            expect { @stream.dup.process frame }.to_not raise_error
          end
        end
      end
    end
  end # end stream states

  context "flow control" do
    it "should initialize to default flow control window" do
      @stream.window.should eq DEFAULT_FLOW_WINDOW
    end

    it "should update window size on DATA frames only" do
      @stream.send HEADERS # go to open
      @stream.window.should eq DEFAULT_FLOW_WINDOW

      (FRAME_TYPES - [DATA,PING,GOAWAY,SETTINGS]).each do |frame|
        s = @stream.dup
        s.send frame
        s.window.should eq DEFAULT_FLOW_WINDOW
      end

      @stream.send DATA
      @stream.window.should eq DEFAULT_FLOW_WINDOW - DATA[:payload].bytesize
    end

    it "should update window size on receipt of WINDOW_UPDATE" do
      @stream.send HEADERS
      @stream.send DATA
      @stream.process WINDOW_UPDATE

      @stream.window.should eq (
        DEFAULT_FLOW_WINDOW - DATA[:payload].bytesize + WINDOW_UPDATE[:increment]
      )
    end

    it "should observe session flow control" do
      settings, data = SETTINGS.dup, DATA.dup
      settings[:payload] = { settings_initial_window_size: 1000 }
      settings[:stream] = 0

      framer = Framer.new
      @conn << framer.generate(settings)

      s1 = @conn.new_stream
      s1.send HEADERS
      s1.send data.merge({payload: "x" * 900, flags: []})
      s1.window.should eq 100

      s1.send data.merge({payload: "x" * 200})
      s1.window.should eq 0
      s1.buffered_amount.should eq 100

      @conn << framer.generate(WINDOW_UPDATE.merge({
        stream: s1.id, increment: 1000
      }))
      s1.buffered_amount.should eq 0
      s1.window.should eq 900
    end
  end

  context "client API" do
    it ".priority should emit PRIORITY frame" do
      @stream.should_receive(:send) do |frame|
        frame[:type].should eq :priority
        frame[:priority].should eq 30
      end

      @stream.priority = 30
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
      data = "x" * HTTP2::MAX_FRAME_SIZE * 2

      @stream.stub(:send)
      @stream.should_receive(:send).exactly(3).times
      @stream.data(data + "x")
    end

    it "should provide stream cancel API"
    it "should provice stream refuse API"
  end

  context "server API" do
    before(:each) do
      @srv = Connection.new(:server)
      @frm = Framer.new
    end

    it "should emit received headers via on(:headers)" do
      headers, recv = {"header" => "value"}, nil
      @conn.on(:frame) {|bytes| @srv << bytes }
      @srv.on(:stream) do |stream|
        stream.on(:headers) {|h| recv = h}
      end

      stream = @conn.new_stream
      stream.headers(headers)

      recv.should eq headers
    end

    it "should emit received payload via on(:data)" do
      payload, recv = "some-payload", nil
      @conn.on(:frame) {|bytes| @srv << bytes }
      @srv.on(:stream) do |stream|
        stream.on(:data) do |recv|
          recv.should eq payload
        end
      end

      stream = @conn.new_stream
      stream.headers({"key" => "value"})
      stream.data(payload)
    end

    it "should emit received priority via on(:priority)" do
      new_priority, recv = 15, 0
      @conn.on(:frame) {|bytes| @srv << bytes }
      @srv.on(:stream) do |stream|
        stream.on(:priority) do |pri|
          pri.should eq new_priority
        end
      end

      stream = @conn.new_stream
      stream.headers({"key" => "value"})
      stream.priority = new_priority
    end
  end
end
