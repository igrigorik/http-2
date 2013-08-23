require "helper"

describe Net::HTTP2::Stream do

  context "stream states" do
    before(:each) do
      @conn = Connection.new
      @stream = @conn.allocate_stream
    end

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
        @stream.reprioritize(30)
        @stream.priority.should eq 30
      end
    end


    # * flow control logic
    #   - initialize to default setting
    #   - decrement on send
    #   - process window_update
    #
    # * API / hooks for listening to PROMISE / HEADERS frames
    # * API for sending .promise, .headers, .data, .reset
    # * Private "send" API which pushes data to Connection object
    #   - push frames
  end
end







