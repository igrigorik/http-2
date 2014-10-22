module HTTP2

  # A single HTTP 2.0 connection can multiplex multiple streams in parallel:
  # multiple requests and responses can be in flight simultaneously and stream
  # data can be interleaved and prioritized.
  #
  # This class encapsulates all of the state, transition, flow-control, and
  # error management as defined by the HTTP 2.0 specification. All you have
  # to do is subscribe to appropriate events (marked with ":" prefix in
  # diagram below) and provide your application logic to handle request
  # and response processing.
  #
  #                         +--------+
  #                    PP   |        |   PP
  #                ,--------|  idle  |--------.
  #               /         |        |         \
  #              v          +--------+          v
  #       +----------+          |           +----------+
  #       |          |          | H         |          |
  #   ,---|:reserved |          |           |:reserved |---.
  #   |   | (local)  |          v           | (remote) |   |
  #   |   +----------+      +--------+      +----------+   |
  #   |      | :active      |        |      :active |      |
  #   |      |      ,-------|:active |-------.      |      |
  #   |      | H   /   ES   |        |   ES   \   H |      |
  #   |      v    v         +--------+         v    v      |
  #   |   +-----------+          |          +-----------+  |
  #   |   |:half_close|          |          |:half_close|  |
  #   |   |  (remote) |          |          |  (local)  |  |
  #   |   +-----------+          |          +-----------+  |
  #   |        |                 v                |        |
  #   |        |    ES/R    +--------+    ES/R    |        |
  #   |        `----------->|        |<-----------'        |
  #   | R                   | :close |                   R |
  #   `-------------------->|        |<--------------------'
  #                         +--------+
  class Stream
    include FlowBuffer
    include Emitter
    include Error

    # Stream ID (odd for client initiated streams, even otherwise).
    attr_reader :id

    # Stream state as defined by HTTP 2.0.
    attr_reader :state

    # Request parent stream of push stream.
    attr_reader :parent

    # Stream priority as set by initiator.
    attr_reader :weight
    attr_reader :dependency

    # Size of current stream flow control window.
    attr_reader :window

    # Reason why connection was closed.
    attr_reader :closed

    # Initializes new stream.
    #
    # Note that you should never have to call this directly. To create a new
    # client initiated stream, use Connection#new_stream. Similarly, Connection
    # will emit new stream objects, when new stream frames are received.
    #
    # @param id [Integer]
    # @param weight [Integer]
    # @param dependency [Integer]
    # @param exclusive [Boolean]
    # @param window [Integer]
    # @param parent [Stream]
    def initialize(connection:, id:, weight: 16, dependency: 0, exclusive: false, window:, parent: nil)
      @connection = connection
      @id = id
      @weight = weight
      @dependency = dependency
      process_priority({weight: weight, stream_dependency: dependency, exclusive: exclusive})
      @window = window
      @parent = parent
      @state  = :idle
      @error  = false
      @closed = false
      @send_buffer = []

      on(:window) { |v| @window = v }
    end

    # Processes incoming HTTP 2.0 frames. The frames must be decoded upstream.
    #
    # @param frame [Hash]
    def receive(frame)
      transition(frame, false)

      case frame[:type]
      when :data
        emit(:data, frame[:payload]) if !frame[:ignore]
      when :headers, :push_promise
        emit(:headers, frame[:payload]) if !frame[:ignore]
      when :priority
        process_priority(frame)
      when :window_update
        @window += frame[:increment]
        send_data
      when :altsvc, :blocked
        emit(frame[:type], frame)
      end

      complete_transition(frame)
    end
    alias :<< :receive

    # Processes outgoing HTTP 2.0 frames. Data frames may be automatically
    # split and buffered based on maximum frame size and current stream flow
    # control window size.
    #
    # @param frame [Hash]
    def send(frame)
      transition(frame, true)
      frame[:stream] ||= @id

      process_priority(frame) if frame[:type] == :priority

      if frame[:type] == :data
        send_data(frame)
      else
        emit(:frame, frame)
      end

      complete_transition(frame)
    end

    # Sends a HEADERS frame containing HTTP response headers.
    #
    # @param headers [Array or Hash] Array of key-value pairs or Hash
    # @param end_headers [Boolean] indicates that no more headers will be sent
    # @param end_stream [Boolean] indicates that no payload will be sent
    def headers(headers, end_headers: true, end_stream: false)
      flags = []
      flags << :end_headers if end_headers
      flags << :end_stream  if end_stream

      send({type: :headers, flags: flags, payload: headers.to_a})
    end

    def promise(headers, end_headers: true, &block)
      raise Exception.new("must provide callback") if !block_given?

      flags = end_headers ? [:end_headers] : []
      emit(:promise, self, headers, flags, &block)
    end

    # Sends a PRIORITY frame with new stream priority value (can only be
    # performed by the client).
    #
    # @param weight [Integer] new stream weight value
    # @param dependency [Integer] new stream dependency stream
    def reprioritize(weight: 16, dependency: 0, exclusive: false)
      stream_error if @id.even?
      send({type: :priority, weight: weight, stream_dependency: dependency, exclusive: exclusive})
    end

    # Sends DATA frame containing response payload.
    #
    # @param payload [String]
    # @param end_stream [Boolean] indicates last response DATA frame
    def data(payload, end_stream: true)
      flags = []
      flags << :end_stream if end_stream

      while payload.bytesize > @connection.max_frame_size do
        chunk = payload.slice!(0, @connection.max_frame_size)
        send({type: :data, payload: chunk})
      end

      send({type: :data, flags: flags, payload: payload})
    end

    # Sends a RST_STREAM frame which closes current stream - this does not
    # close the underlying connection.
    #
    # @param error [:Symbol] optional reason why stream was closed
    def close(error = :stream_closed)
      send({type: :rst_stream, error: error})
    end

    # Sends a RST_STREAM indicating that the stream is no longer needed.
    def cancel
      send({type: :rst_stream, error: :cancel})
    end

    # Sends a RST_STREAM indicating that the stream has been refused prior
    # to performing any application processing.
    def refuse
      send({type: :rst_stream, error: :refused_stream})
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
          when :push_promise then event(:reserved_local)
          when :headers
            if end_stream?(frame)
              event(:half_closed_local)
            else
              event(:open)
            end
          when :rst_stream then event(:local_rst)
          else stream_error; end
        else
          case frame[:type]
          when :push_promise then event(:reserved_remote)
          when :headers
            if end_stream?(frame)
              event(:half_closed_remote)
            else
              event(:open)
            end
          else stream_error(:protocol_error); end
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
          when :headers     then event(:half_closed_remote)
          when :rst_stream  then event(:local_rst)
          else stream_error; end
        else
          @state = case frame[:type]
          when :rst_stream  then event(:remote_rst)
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
          when :rst_stream then event(:local_rst)
          when :priority then @state
          else stream_error; end
        else
          @state = case frame[:type]
          when :headers     then event(:half_closed_local)
          when :rst_stream  then event(:remote_rst)
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
            event(:half_closed_local) if end_stream?(frame)
          when :rst_stream then event(:local_rst)
          end
        else
          case frame[:type]
          when :data, :headers, :continuation
            event(:half_closed_remote) if end_stream?(frame)
          when :rst_stream then event(:remote_rst)
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
          case frame[:type]
          when :rst_stream
            event(:local_rst)
          when :priority
            process_priority(frame)
          else
            stream_error
          end
        else
          case frame[:type]
          when :data, :headers, :continuation
            event(:remote_closed) if end_stream?(frame)
          when :rst_stream then event(:remote_rst)
          when :priority
            process_priority(frame)
          when :window_update
            frame[:ignore] = true
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
            event(:local_closed) if end_stream?(frame)
          when :rst_stream then event(:local_rst)
          end
        else
          case frame[:type]
          when :rst_stream then event(:remote_rst)
          when :window_update then frame[:ignore] = true
          when :priority
            process_priority(frame)
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
          when :priority   then
            process_priority(frame)
          else
            stream_error(:stream_closed) if !(frame[:type] == :rst_stream)
          end
        else
          if frame[:type] == :priority
            process_priority(frame)
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
    end

    def event(newstate)
      case newstate
      when :open
        @state = newstate
        emit(:active)

      when :reserved_local, :reserved_remote
        @state = newstate
        emit(:reserved)

      when :half_closed_local, :half_closed_remote
        @closed = newstate
        emit(:active) unless @state == :open
        @state = :half_closing

      when :local_closed, :remote_closed, :local_rst, :remote_rst
        @closed = newstate
        @state  = :closing
      end

      @state
    end

    def complete_transition(frame)
      case @state
      when :closing
        @state = :closed
        emit(:close, frame[:error])
      when :half_closing
        @state = @closed
        emit(:half_close)
      end
    end

    def process_priority(frame)
      @weight = frame[:weight]
      @dependency = frame[:stream_dependency]
      emit(:priority,
           weight:      frame[:weight],
           dependency:  frame[:stream_dependency],
           exclusive:   frame[:exclusive])
      # TODO: implement dependency tree housekeeping
    end

    def end_stream?(frame)
      case frame[:type]
      when :data, :headers, :continuation
        frame[:flags].include?(:end_stream)
      else false; end
    end

    def stream_error(error = :stream_error, msg: nil)
      @error = error
      close(error) if @state != :closed

      klass = error.to_s.split('_').map(&:capitalize).join
      raise Error.const_get(klass).new(msg)
    end
  end
end
