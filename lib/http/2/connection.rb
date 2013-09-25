module HTTP2

  # Default connection and stream flow control window (64KB).
  DEFAULT_FLOW_WINDOW = 65535

  # Default stream priority (lower values are higher priority).
  DEFAULT_PRIORITY    = 2**30

  # Default connection "fast-fail" preamble string as defined by the spec.
  CONNECTION_HEADER   = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  # Connection encapsulates all of the connection, stream, flow-control,
  # error management, and other processing logic required for a well-behaved
  # HTTP 2.0 client.
  #
  # When the connection object is instantiated you must specify its role
  # (:client or :server) to initialize appropriate header compression
  # and decompression algorithms and stream management logic.
  #
  # Your code is responsible for feeding data to connection object, which
  # performs all of the necessary HTTP 2.0 decoding, state management and
  # the rest, and vice versa, the parser will emit bytes (encoded HTTP 2.0
  # frames) that you can then route to the destination. Roughly, this works
  # as follows:
  #
  # @example
  #     socket = YourTransport.new
  #
  #     conn = HTTP2::Connection.new(:client)
  #     conn.on(:frame) {|bytes| socket << bytes }
  #
  #     while bytes = socket.read
  #       conn << bytes
  #     end
  #
  class Connection
    include FlowBuffer
    include Emitter
    include Error

    # Type of connection (:server, :client).
    attr_reader :type

    # Connection state (:new, :closed).
    attr_reader :state

    # Last connection error if connection is aborted.
    attr_reader :error

    # Size of current connection flow control window (by default, set to
    # infinity, but is automatically updated on receipt of peer settings).
    attr_reader :window

    # Maximum number of concurrent streams allowed by the peer (automatically
    # updated on receipt of peer settings).
    attr_reader :stream_limit

    # Number of active streams between client and server (reserved streams
    # are not counted towards the stream limit).
    attr_reader :active_stream_count

    # Initializes new client or server connection object.
    #
    # @param type [Symbol]
    def initialize(type = :client)
      @type = type

      if @type == :server
        @stream_id    = 2
        @compressor   = Header::Compressor.new(:response)
        @decompressor = Header::Decompressor.new(:request)
      else
        @stream_id    = 1
        @compressor   = Header::Compressor.new(:request)
        @decompressor = Header::Decompressor.new(:response)
      end

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

    # Allocates new stream for current connection.
    #
    # @param priority [Integer]
    # @param window [Integer]
    # @param parent [Stream]
    def new_stream(priority: DEFAULT_PRIORITY, window: @window_limit, parent: nil)
      raise ConnectionClosed.new if @state == :closed
      raise StreamLimitExceeded.new if @active_stream_count == @stream_limit

      stream = activate_stream(@stream_id, priority, window, parent)
      @stream_id += 2

      stream
    end

    # Sends PING frame to the peer.
    #
    # @param payload [String] optional payload must be 8 bytes long
    # @param blk [Proc] callback to execute when PONG is received
    def ping(payload, &blk)
      process({type: :ping, stream: 0, payload: payload})
      once(:pong, &blk) if blk
    end

    # Sends a GOAWAY frame indicating that the peer should stop creating
    # new streams for current connection.
    #
    # Endpoints MAY append opaque data to the payload of any GOAWAY frame.
    # Additional debug data is intended for diagnostic purposes only and
    # carries no semantic value. Debug data MUST NOT be persistently stored,
    # since it could contain sensitive information.
    #
    # @param error [Symbol]
    # @param payload [String]
    def goaway(error = :no_error, payload = nil)
      process({
        type: :goaway, last_stream: (@streams.max.first rescue 0),
        error: error, payload: payload
      })
      @state = :closed
    end

    # Sends a connection SETTINGS frame to the peer. Available settings are:
    # - :settings_max_concurrent_streams
    # - :settings_flow_control_options (value "1" disables flow control)
    # - :settings_initial_window_size
    #
    # @param payload [Hash]
    def settings(payload)
      process({type: :settings, stream: 0, payload: payload})
    end

    # Decodes incoming bytes into HTTP 2.0 frames and routes them to
    # appropriate receivers: connection frames are handled directly, and
    # stream frames are passed to appropriate stream objects.
    #
    # @param data [String] Binary encoded string
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

          @continuation << frame
          return if !frame[:flags].include? :end_headers

          headers = @continuation.collect do |chunk|
            decode_headers(chunk)
            chunk[:payload]
          end.flatten(1)

          frame = @continuation.shift
          @continuation.clear

          frame.delete(:length)
          frame[:payload] = headers
          frame[:flags] << if frame[:type] == :push_promise
            :end_push_promise
          else
            :end_headers
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
            decode_headers(frame)
            return if @state == :closed

            stream = @streams[frame[:stream]]
            if stream.nil?
              stream = activate_stream(frame[:stream],
                                       frame[:priority] || DEFAULT_PRIORITY,
                                       @window_limit)
              emit(:stream, stream)
            end

            stream << frame

          when :push_promise
            # The last frame in a sequence of PUSH_PROMISE/CONTINUATION
            # frames MUST have the END_PUSH_PROMISE/END_HEADERS flag set
            if !frame[:flags].include? :end_push_promise
              @continuation << frame
              return
            end

            decode_headers(frame)
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

            connection_error(msg: 'missing parent ID') if parent.nil?

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

            stream = activate_stream(pid, DEFAULT_PRIORITY, @window_limit, parent)
            emit(:promise, stream)
            stream << frame
          else
            if stream = @streams[frame[:stream]]
              stream << frame
            else
              # An endpoint that receives an unexpected stream identifier
              # MUST respond with a connection error of type PROTOCOL_ERROR.
              connection_error
            end
          end
        end
      end
    end
    alias :<< :receive

    private

    def process(frame)
      if frame[:type] == :data
        send_data(frame, true)

      else
        # An endpoint can end a connection at any time. In particular, an
        # endpoint MAY choose to treat a stream error as a connection error.
        if frame[:type] == :rst_stream
          if frame[:error] == :protocol_error
            goaway(frame[:error])
          end
        else
          emit(:frame, encode(frame))
        end
      end
    end

    def encode(frame)
      if frame[:type] == :headers ||
         frame[:type] == :push_promise
        encode_headers(frame)
      end

      @framer.generate(frame)
    end

    def connection_frame?(frame)
      frame[:stream] == 0 ||
      frame[:type] == :settings ||
      frame[:type] == :ping ||
      frame[:type] == :goaway
    end

    def connection_management(frame)
      case @state
      when :new
        # SETTINGS frames MUST be sent at the start of a connection.
        connection_settings(frame)
        @state = :connected

      when :connected
        case frame[:type]
        when :settings
          connection_settings(frame)
        when :window_update
          flow_control_allowed?
          @window += frame[:increment]
          send_data(nil, true)
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
    def decode_headers(frame)
      if frame[:payload].is_a? String
        frame[:payload] = @decompressor.decode(StringIO.new(frame[:payload]))
      end

    rescue Exception => e
      connection_error(:compression_error)
    end

    def encode_headers(frame)
      if !frame[:payload].is_a? String
        frame[:payload] = @compressor.encode(frame[:payload])
      end

    rescue Exception => e
      connection_error(:compression_error)
    end

    def flow_control_allowed?
      if @window_limit == Float::INFINITY
        connection_error(:flow_control_error)
      end
    end

    def activate_stream(id, priority, window, parent = nil)
      if @streams.key?(id)
        connection_error(msg: 'Stream ID already exists')
      end

      stream = Stream.new(id, priority, window, parent)

      # Streams that are in the "open" state, or either of the "half closed"
      # states count toward the maximum number of streams that an endpoint is
      # permitted to open.
      stream.once(:active) { @active_stream_count += 1 }
      stream.once(:close)  { @active_stream_count -= 1 }
      stream.on(:promise, &method(:promise))
      stream.on(:frame,   &method(:process))

      @streams[id] = stream
    end

    def promise(*args, &callback)
      if @type == :client
        raise ProtocolError.new("client cannot initiate promise")
      end

      parent, headers, flags = *args
      promise = new_stream(parent: parent)
      promise.send({
        type: :push_promise,
        flags: flags,
        stream: parent.id,
        promise_stream: promise.id,
        payload: headers.to_a
      })

      callback.call(promise)
    end

    def connection_error(error = :protocol_error, msg: nil)
      goaway(error) if @state != :closed && @state != :new

      @state, @error = :closed, error
      klass = error.to_s.split('_').map(&:capitalize).join
      raise Kernel.const_get(klass).new(msg)
    end

  end
end
