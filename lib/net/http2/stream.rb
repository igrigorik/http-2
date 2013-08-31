module Net
  module HTTP2

    class Stream
      include Emitter
      attr_reader :state, :priority, :window, :id

      DEFAULT_PRIORITY = 2**30

      def initialize(conn, id, priority = DEFAULT_PRIORITY)
        @conn = conn
        @id = id

        @priority = priority
        @window = DEFAULT_FLOW_WINDOW
        @state  = :idle
        @error  = false
        @closed = false
      end

      def process(frame)
        transition(frame, false)

        case frame[:type]
        when :priority
          @priority = frame[:priority]
        when :window_update
          @window += frame[:increment]
        end
      end

      def send(frame)
        transition(frame, true)

        case frame[:type]
        when :priority
          @priority = frame[:priority]
        when :data
          @window -= frame[:payload].bytesize
        end

        frame[:stream] = @id

        @conn.send frame
      end

      def headers(head, end_headers: true, end_stream: false)
        flags = []
        flags << :end_headers if end_headers
        flags << :end_stream  if end_stream

        send({type: :headers, flags: flags, payload: head})
      end

      def promise(head)
        send({type: :push_promise, payload: head})
      end

      def priority=(p)
        send({type: :priority, priority: p})
      end

      def data(d, end_stream: true)
        flags = []
        flags << :end_stream if end_stream

        send({type: :data, flags: flags, payload: d})
      end

      def close(error = :stream_closed)
        send({type: :rst_stream, error: error})
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
              event(:open) # transition through open to half closed
              @state = :half_closed_local if end_stream?(frame)
            else StreamError.new; end # local error, don't send RST_STREAM
          else
            case frame[:type]
            when :push_promise
              @state = :reserved_remote
            when :headers
              event(:open) # transition through open to half closed
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
            when :rst_stream  then event(:local_rst, frame)
            else stream_error; end
          else
            @state = case frame[:type]
            when :rst_stream  then event(:remote_rst, frame)
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
            when :rst_stream then event(:local_rst, frame)
            when :priority then @state
            else stream_error; end
          else
            @state = case frame[:type]
            when :headers     then :half_closed_local
            when :rst_stream  then event(:remote_rst, frame)
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
            case frame[:type]
            when :data, :headers, :continuation
              @state = :half_closed_local if end_stream?(frame)
            when :rst_stream then event(:local_rst, frame)
            end
          else
            case frame[:type]
            when :data, :headers, :continuation
              @state = :half_closed_remote if end_stream?(frame)
            when :rst_stream then event(:remote_rst, frame)
            end
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
              event(:local_rst, frame)
            else
              stream_error
            end
          else
            case frame[:type]
            when :data, :headers, :continuation
              event(:remote_closed, frame) if end_stream?(frame)
            when :rst_stream then event(:remote_rst, frame)
            when :window_update, :priority
              frame[:igore] = true
            end
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
            case frame[:type]
            when :data, :headers, :continuation
              event(:local_closed, frame) if end_stream?(frame)
            when :rst_stream then event(:local_rst, frame)
            end
          else
            case frame[:type]
            when :rst_stream then event(:remote_rst, frame)
            when :window_update then frame[:ignore] = true
            else stream_error(:stream_closed); end
          end

        # An endpoint MUST NOT send frames on a closed stream. An endpoint
        # that receives a frame after receiving a RST_STREAM or a frame
        # containing a END_STREAM flag on that stream MUST treat that as a
        # stream error (Section 5.4.2) of type STREAM_CLOSED.
        #
        # WINDOW_UPDATE or PRIORITY frames can be received in this state for
        # a short period after a a frame containing an END_STREAM flag is
        # sent.  Until the remote peer receives and processes the frame
        # bearing the END_STREAM flag, it might send either frame type.
        #
        # If this state is reached as a result of sending a RST_STREAM
        # frame, the peer that receives the RST_STREAM might have already
        # sent - or enqueued for sending - frames on the stream that cannot
        # be withdrawn. An endpoint MUST ignore frames that it receives on
        # closed streams after it has sent a RST_STREAM frame.
        #
        # An endpoint might receive a PUSH_PROMISE or a CONTINUATION frame
        # after it sends RST_STREAM. PUSH_PROMISE causes a stream to become
        # "reserved". If promised streams are not desired, a RST_STREAM can
        # be used to close any of those streams.
        when :closed
          if sending
            case frame[:type]
            when :rst_stream then # ignore
            else raise StreamError.new('stream closed'); end # already closed
          else
            case @closed
            when :remote_rst, :remote_closed
              stream_error(:stream_closed) if !(frame[:type] == :rst_stream)
            when :local_rst, :local_closed
              frame[:ignore] = true
            end
          end
        end
      end

      def event(state, frame = nil)
        case state
        when :open
          @state = state
          emit(:active)
        when :local_closed, :remote_closed, :local_rst, :remote_rst
          @closed = state
          @state  = :closed
          emit(:close, frame[:error])
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
        @error = error

        send({type: :rst_stream, stream: @id, error: error})
        raise StreamError.new(error.to_s.gsub('_',' '))
      end

    end
  end
end
