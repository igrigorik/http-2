module Net
  module HTTP2

    DEFAULT_FLOW_WINDOW = 65535
    DEFAULT_PRIORITY    = 2**30
    CONNECTION_HEADER   = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

    class Connection
      include FrameSplitter
      include Emitter

      attr_reader :type, :window, :state, :error
      attr_reader :stream_limit, :active_stream_count

      def initialize(type = :client)
        @type = type

        @stream_id = (@type == :client) ? 1 : 2
        @stream_limit = Float::INFINITY
        @active_stream_count = 0
        @streams = {}

        @framer = Framer.new
        @window = DEFAULT_FLOW_WINDOW
        @window_limit = DEFAULT_FLOW_WINDOW

        @recv_buffer = Buffer.new
        @send_buffer = []
        @continuation = []
        @state = :new
        @error = nil
      end

      def new_stream
        raise StreamLimitExceeded.new if @active_stream_count == @stream_limit
        raise ConnectionClosed.new if @state == :closed

        @stream_id += 2
        activate_stream(@stream_id)
      end

      def ping(data, &blk)
        process({type: :ping, stream: 0, payload: data})
        once(:pong, &blk) if blk
      end

      # Endpoints MAY append opaque data to the payload of any GOAWAY frame.
      # Additional debug data is intended for diagnostic purposes only and
      # carries no semantic value.  Debug data MUST NOT be persistently
      # stored, since it could contain sensitive information.
      def goaway(error = :no_error, payload = nil)
        process({
          type: :goaway, last_stream: (@streams.max.first rescue 0),
          error: error, payload: payload
        })
        @state = :closed
      end

      def receive(data)
        @recv_buffer << data

        while frame = @framer.parse(@recv_buffer) do
          # Header blocks MUST be transmitted as a contiguous sequence of frames
          # with no interleaved frames of any other type, or from any other stream.
          if !@continuation.empty?
            if frame[:type]  != :continuation ||
               frame[:stream] != @continuation.first[:stream]
              connection_error
            end

            if !frame[:flags].include? :end_headers
              @continuation << frame
              return
            end
          end

          # SETTINGS frames always apply to a connection, never a single stream.
          # The stream identifier for a settings frame MUST be zero.  If an
          # endpoint receives a SETTINGS frame whose stream identifier field is
          # anything other than 0x0, the endpoint MUST respond with a connection
          # error (Section 5.4.1) of type PROTOCOL_ERROR.
          if connection_frame?(frame)
            connection_management(frame)
          else
            case frame[:type]
            when :headers
              # The last frame in a sequence of HEADERS/CONTINUATION
              # frames MUST have the END_HEADERS flag set.
              if !frame[:flags].include? :end_headers
                @continuation << frame
                return
              end

              # After sending a GOAWAY frame, the sender can discard frames
              # for new streams.  However, any frames that alter connection
              # state cannot be completely ignored.  For instance, HEADERS,
              # PUSH_PROMISE and CONTINUATION frames MUST be minimally
              # processed to ensure a consistent compression state
              decode_headers
              return if @state == :closed

              stream = @streams[frame[:stream]]
              if stream.nil?
                stream = activate_stream(frame[:stream], frame[:priority])
                emit(:stream, stream)
              end

              stream.process(frame)

            when :push_promise
              # The last frame in a sequence of PUSH_PROMISE/CONTINUATION
              # frames MUST have the END_PUSH_PROMISE/END_HEADERS flag set
              if !frame[:flags].include? :end_push_promise
                @continuation << frame
                return
              end

              decode_headers
              return if @state == :closed

              # PUSH_PROMISE frames MUST be associated with an existing, peer-
              # initiated stream... A receiver MUST treat the receipt of a
              # PUSH_PROMISE on a stream that is neither "open" nor
              # "half-closed (local)" as a connection error (Section 5.4.1) of
              # type PROTOCOL_ERROR. Similarly, a receiver MUST treat the
              # receipt of a PUSH_PROMISE that promises an illegal stream
              # identifier (Section 5.1.1) (that is, an identifier for a stream
              # that is not currently in the "idle" state) as a connection error
              # (Section 5.4.1) of type PROTOCOL_ERROR, unless the receiver
              # recently sent a RST_STREAM frame to cancel the associated stream.
              parent = @streams[frame[:stream]]
              pid = frame[:promise_stream]

              connection_error if parent.nil?
              connection_error if @streams.include? pid

              if !(parent.state == :open || parent.state == :half_closed_local)
                # An endpoint might receive a PUSH_PROMISE frame after it sends
                # RST_STREAM.  PUSH_PROMISE causes a stream to become "reserved".
                # The RST_STREAM does not cancel any promised stream.  Therefore, if
                # promised streams are not desired, a RST_STREAM can be used to
                # close any of those streams.
                if parent.closed == :local_rst
                  # We can either (a) 'resurrect' the parent, or (b) RST_STREAM
                  # ... sticking with (b), might need to revisit later.
                  process({type: :rst_stream, stream: pid, error: :refused_stream})
                else
                  connection_error
                end
              end

              stream = activate_stream(pid)
              emit(:promise, stream)
              stream.process(frame)
            else
              @streams[frame[:stream]].process frame
            end
          end
        end
      end
      alias :<< :receive

      private

      def process(frame)
        if frame[:type] != :data
          # send immediately
        else
          send_data(frame)
        end
      end

      def connection_frame?(frame)
        frame[:stream] == 0 ||
        frame[:type] == :settings ||
        frame[:type] == :window_update ||
        frame[:type] == :ping ||
        frame[:type] == :goaway
      end

      def connection_management(frame)
        case @state
        # SETTINGS frames MUST be sent at the start of a connection.
        when :new
          connection_settings(frame)
          @state = :connected

        when :connected
          case frame[:type]
          when :settings
            connection_settings(frame)
          when :window_update
            flow_control_allowed?
            @window += frame[:increment]
            send_data
          when :ping
            if frame[:flags].include? :pong
              emit(:pong, frame[:payload])
            else
              process({
                type: :ping, stream: 0,
                flags: [:pong], payload: frame[:payload]
              })
            end
          when :goaway
            # Receivers of a GOAWAY frame MUST NOT open additional streams on
            # the connection, although a new connection can be established
            # for new streams.
            @state = :closed
            emit(:goaway, frame[:last_stream], frame[:error], frame[:payload])

          else
            connection_error
          end
        else
          connection_error
        end
      end

      def connection_settings(frame)
        if (frame[:type] != :settings || frame[:stream] != 0)
          connection_error
        end

        frame[:payload].each do |key,v|
          case key
          when :settings_max_concurrent_streams
            @stream_limit = v

          # A change to SETTINGS_INITIAL_WINDOW_SIZE could cause the available
          # space in a flow control window to become negative. A sender MUST
          # track the negative flow control window, and MUST NOT send new flow
          # controlled frames until it receives WINDOW_UPDATE frames that cause
          # the flow control window to become positive.
          when :settings_initial_window_size
            flow_control_allowed?
            @window = @window - @window_limit + v
            @streams.each do |id, stream|
              stream.emit(:window, stream.window - @window_limit + v)
            end

            @window_limit = v

          # Flow control can be disabled the entire connection using the
          # SETTINGS_FLOW_CONTROL_OPTIONS setting. This setting ends all forms
          # of flow control. An implementation that does not wish to perform
          # flow control can use this in the initial SETTINGS exchange.
          when :settings_flow_control_options
            flow_control_allowed?

            if v == 1
              @window = @window_limit = Float::INFINITY
            end
          end
        end
      end

      # The receiving endpoint reassembles the header block by concatenating
      # the individual fragments, then decompresses the block to reconstruct
      # the header set.
      def decode_headers

      end

      def flow_control_allowed?
        if @window_limit == Float::INFINITY
          connection_error(:flow_control_error)
        end
      end

      def activate_stream(id, priority = DEFAULT_PRIORITY)
        stream = Stream.new(id, priority, @window)

        # Streams that are in the "open" state, or either of the "half closed"
        # states count toward the maximum number of streams that an endpoint is
        # permitted to open.
        stream.once(:active) { @active_stream_count += 1 }
        stream.once(:close)  { @active_stream_count -= 1 }
        stream.on(:frame)    { |frame| process(frame) }

        @streams[id] = stream
      end

      def connection_error(error = :protocol_error)
        if @state != :closed
          process({type: :rst_stream, stream: 0, error: error})
        end

        @state, @error = :closed, error
        klass = error.to_s.split('_').map(&:capitalize).join
        raise Kernel.const_get(klass).new
      end

    end
  end
end
