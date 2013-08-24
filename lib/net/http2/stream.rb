module Net
  module HTTP2

    class ProtocolError < Exception; end
    class StreamError < ProtocolError; end

    class Stream
      DEFAULT_PRIORITY = 2**30

      attr_reader :state, :priority

      def initialize(conn, id, priority = DEFAULT_PRIORITY)
        @conn = conn
        @id = id

        @priority = priority
        @state = :idle
      end

      def on_open(&blk); @on_open = blk; end
      def on_close(&blk); @on_close = blk; end

      def process(frame)
        transition(frame, false)

        case frame[:type]
        when :priority
          @priority = frame[:priority]
        end
      end

      def send(frame)
        transition(frame, true)

        case frame[:type]
        when :priority
          @priority = frame[:priority]
        end
      end

      def reprioritize(pri)
        send({type: :priority, stream: @id, priority: pri})
      end

      def close(error = :stream_closed)
        send({type: :rst_stream, stream: @id, error: error})
      end

      private

      # HTTP 2.0 Stream States
      # - http://tools.ietf.org/html/draft-ietf-httpbis-http2-05#section-5
      #
      #                       +--------+
      #                 PP    |        |    PP
      #              ,--------|  idle  |--------.
      #             /         |        |         \
      #            v          +--------+          v
      #     +----------+          |           +----------+
      #     |          |          | H         |          |
      # ,---| reserved |          |           | reserved |---.
      # |   | (local)  |          v           | (remote) |   |
      # |   +----------+      +--------+      +----------+   |
      # |      |          ES  |        |  ES          |      |
      # |      | H    ,-------|  open  |-------.      | H    |
      # |      |     /        |        |        \     |      |
      # |      v    v         +--------+         v    v      |
      # |   +----------+          |           +----------+   |
      # |   |   half   |          |           |   half   |   |
      # |   |  closed  |          | R         |  closed  |   |
      # |   | (remote) |          |           | (local)  |   |
      # |   +----------+          |           +----------+   |
      # |        |                v                 |        |
      # |        |  ES / R    +--------+  ES / R    |        |
      # |        `----------->|        |<-----------'        |
      # |  R                  | closed |                  R  |
      # `-------------------->|        |<--------------------'
      #                       +--------+
      #
      def transition(frame, sending)
        case @state

        # All streams start in the "idle" state.  In this state, no frames
        # have been exchanged.
        # *  Sending or receiving a HEADERS frame causes the stream to
        #    become "open".  The stream identifier is selected as described
        #    in Section 5.1.1.
        # *  Sending a PUSH_PROMISE frame marks the associated stream for
        #    later use.  The stream state for the reserved stream
        #    transitions to "reserved (local)".
        # *  Receiving a PUSH_PROMISE frame marks the associated stream as
        #    reserved by the remote peer.  The state of the stream becomes
        #    "reserved (remote)".
        when :idle
          if sending
            case frame[:type]
            when :push_promise
              @state = :reserved_local
            when :headers
              emit(:open)
              @state = :half_closed_local if end_stream?(frame)
            else StreamError.new; end # local error, don't send RST_STREAM
          else
            case frame[:type]
            when :push_promise
              @state = :reserved_remote
            when :headers
              emit(:open)
              @state = :half_closed_remote if end_stream?(frame)
            else stream_error; end
          end

        # A stream in the "reserved (local)" state is one that has been
        # promised by sending a PUSH_PROMISE frame.  A PUSH_PROMISE frame
        # reserves an idle stream by associating the stream with an open
        # stream that was initiated by the remote peer (see Section 8.2).
        # *  The endpoint can send a HEADERS frame.  This causes the stream
        #    to open in a "half closed (remote)" state.
        # *  Either endpoint can send a RST_STREAM frame to cause the stream
        #    to become "closed".  This also releases the stream reservation.
        # An endpoint MUST NOT send any other type of frame in this state.
        # Receiving any frame other than RST_STREAM or PRIORITY MUST be
        # treated as a connection error (Section 5.4.1) of type
        # PROTOCOL_ERROR.
        when :reserved_local
          if sending
            @state = case frame[:type]
            when :headers     then :half_closed_remote
            when :rst_stream  then emit(:closed, frame)
            else stream_error; end
          else
            @state = case frame[:type]
            when :rst_stream  then emit(:closed, frame)
            when :priority    then @state
            else stream_error; end
          end

        # A stream in the "reserved (remote)" state has been reserved by a
        # remote peer.
        # *  Receiving a HEADERS frame causes the stream to transition to
        #    "half closed (local)".
        # *  Either endpoint can send a RST_STREAM frame to cause the stream
        #    to become "closed".  This also releases the stream reservation.
        # Receiving any other type of frame MUST be treated as a stream
        # error (Section 5.4.2) of type PROTOCOL_ERROR.  An endpoint MAY
        # send RST_STREAM or PRIORITY frames in this state to cancel or
        # reprioritize the reserved stream.
        when :reserved_remote
          if sending
            @state = case frame[:type]
            when :rst_stream then emit(:closed, frame)
            when :priority then @state
            else stream_error; end
          else
            @state = case frame[:type]
            when :headers     then :half_closed_local
            when :rst_stream  then emit(:closed, frame)
            else stream_error; end
          end

        # The "open" state is where both peers can send frames of any type.
        # In this state, sending peers observe advertised stream level flow
        # control limits (Section 5.2).
        # * From this state either endpoint can send a frame with a END_STREAM
        #   flag set, which causes the stream to transition into one of the
        #   "half closed" states: an endpoint sending a END_STREAM flag causes
        #   the stream state to become "half closed (local)"; an endpoint
        #   receiving a END_STREAM flag causes the stream state to become
        #   "half closed (remote)".
        # * Either endpoint can send a RST_STREAM frame from this state,
        #   causing it to transition immediately to "closed".
        when :open
          if sending
            @state = case frame[:type]
            when :data, :headers, :continuation
              frame[:flags].include?(:end_stream) ? :half_closed_local : @state
            when :rst_stream then emit(:closed, frame)
            else @state; end
          else
            @state = case frame[:type]
            when :data, :headers, :continuation
              frame[:flags].include?(:end_stream) ? :half_closed_remote : @state
            when :rst_stream then emit(:closed, frame)
            else @state; end
          end

        # A stream that is "half closed (local)" cannot be used for sending
        # frames.
        # A stream transitions from this state to "closed" when a frame that
        # contains a END_STREAM flag is received, or when either peer sends
        # a RST_STREAM frame.
        # A receiver can ignore WINDOW_UPDATE or PRIORITY frames in this
        # state.  These frame types might arrive for a short period after a
        # frame bearing the END_STREAM flag is sent.
        when :half_closed_local
          if sending
            if frame[:type] == :rst_stream
              emit(:closed, frame)
            else
              stream_error
            end
          else
            @state = case frame[:type]
            when :data, :headers, :continuation
              frame[:flags].include?(:end_stream) ? emit(:closed, frame) : @state
            when :rst_stream then emit(:closed, frame)
            else @state; end
          end

        # A stream that is "half closed (remote)" is no longer being used by
        # the peer to send frames.  In this state, an endpoint is no longer
        # obligated to maintain a receiver flow control window if it
        # performs flow control.
        # If an endpoint receives additional frames for a stream that is in
        # this state it MUST respond with a stream error (Section 5.4.2) of
        # type STREAM_CLOSED.
        # A stream can transition from this state to "closed" by sending a
        # frame that contains a END_STREAM flag, or when either peer sends a
        # RST_STREAM frame.
        when :half_closed_remote
          if sending
            @state = case frame[:type]
            when :data, :headers, :continuation
              frame[:flags].include?(:end_stream) ? emit(:closed, frame) : @state
            when :rst_stream then emit(:closed, frame)
            else @state; end
          else
            if frame[:type] == :rst_stream
              emit(:closed, frame)
            else
              stream_error(:stream_closed)
            end
          end
        end
      end

      def emit(state, frame = nil)
        @state = state

        case state
        when :open   then @on_open.call if @on_open
        when :closed then @on_close.call(frame[:error]) if @on_close
        end

        @state
      end

      def end_stream?(frame)
        case frame[:type]
        when :data, :headers, :continuation
          frame[:flags].include?(:end_stream)
        else false; end
      end

      def stream_error(error = :protocol_error)
        send({type: :rst_stream, stream: @id, error: error})
        raise StreamError.new(error.to_s.gsub('_',' '))
      end

    end
  end
end
