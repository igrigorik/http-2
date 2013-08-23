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
            @state = case frame[:type]
            when :push_promise then :reserved_local
            when :headers      then :open
            else StreamError.new; end # local error, don't send RST_STREAM
          else
            @state = case frame[:type]
            when :push_promise then :reserved_remote
            when :headers      then :open
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
            when :rst_stream  then :closed
            else stream_error; end
          else
            @state = case frame[:type]
            when :rst_stream  then :closed
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
            when :rst_stream then :closed
            when :priority then @state
            else stream_error; end
          else
            @state = case frame[:type]
            when :headers     then :half_closed_local
            when :rst_stream  then :closed
            else stream_error; end
          end
        end
      end

      def stream_error(msg = nil)
        send({type: :rst_stream, stream: @id, error: :protocol_error})
        raise StreamError.new(msg)
      end

    end
  end
end

