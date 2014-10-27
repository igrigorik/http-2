module HTTP2

  # Default connection and stream flow control window (64KB).
  DEFAULT_FLOW_WINDOW = 65535

  # Default header table size
  DEFAULT_HEADER_SIZE = 4096

  # Default stream_limit
  DEFAULT_MAX_CONCURRENT_STREAMS = 100

  # Default values for SETTINGS frame, as defined by the spec.
  SPEC_DEFAULT_CONNECTION_SETTINGS = {
    settings_header_table_size:       4096,
    settings_enable_push:             1,                     # enabled for servers
    settings_max_concurrent_streams:  Framer::MAX_STREAM_ID, # unlimited
    settings_initial_window_size:     65535,
    settings_max_frame_size:          16384,
    settings_max_header_list_size:    2**31 - 1,             # unlimited
  }.freeze

  DEFAULT_CONNECTIONS_SETTINGS = {
    settings_header_table_size:       4096,
    settings_enable_push:             1,     # enabled for servers
    settings_max_concurrent_streams:  100,
    settings_initial_window_size:     65535, #
    settings_max_frame_size:          16384,
    settings_max_header_list_size:    2**31 - 1,             # unlimited
  }.freeze

  # Default stream priority (lower values are higher priority).
  DEFAULT_WEIGHT    = 16

  # Default connection "fast-fail" preamble string as defined by the spec.
  CONNECTION_HEADER   = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  # Connection encapsulates all of the connection, stream, flow-control,
  # error management, and other processing logic required for a well-behaved
  # HTTP 2.0 endpoint.
  #
  # Note that this class should not be used directly. Instead, you want to
  # use either Client or Server class to drive the HTTP 2.0 exchange.
  class Connection
    include FlowBuffer
    include Emitter
    include Error

    # Connection state (:new, :closed).
    attr_reader :state

    # Last connection error if connection is aborted.
    attr_reader :error

    # Size of current connection flow control window (by default, set to
    # infinity, but is automatically updated on receipt of peer settings).
    attr_reader :window

    # Max frame size
    attr_reader :max_frame_size
    def max_frame_size=(size)
      @framer.max_frame_size = @max_frame_size = size
    end

    # Current value of connection SETTINGS
    def settings_value; @settings; end

    # Pending settings value
    #  Sent but not ack'ed settings
    attr_reader :pending_settings

    # Number of active streams between client and server (reserved streams
    # are not counted towards the stream limit).
    attr_reader :active_stream_count

    # Initializes new connection object.
    #
    def initialize(**settings)
      @settings = DEFAULT_CONNECTIONS_SETTINGS.merge(settings)

      @compressor   = Header::Compressor.new(settings)
      @decompressor = Header::Decompressor.new(settings)

      @active_stream_count = 0
      @streams = {}
      @pending_settings = []

      @framer = Framer.new

      @window_limit = @settings[:settings_initial_window_size]
      @window = @window_limit

      self.max_frame_size = @settings[:settings_max_frame_size]

      @recv_buffer = Buffer.new
      @send_buffer = []
      @continuation = []
      @error = nil
    end

    # Allocates new stream for current connection.
    #
    # @param priority [Integer]
    # @param window [Integer]
    # @param parent [Stream]
    def new_stream(**args)
      raise ConnectionClosed.new if @state == :closed
      raise StreamLimitExceeded.new if @active_stream_count == @settings[:settings_max_concurrent_streams]

      stream = activate_stream(id: @stream_id, **args)
      @stream_id += 2

      stream
    end

    # Sends PING frame to the peer.
    #
    # @param payload [String] optional payload must be 8 bytes long
    # @param blk [Proc] callback to execute when PONG is received
    def ping(payload, &blk)
      send({type: :ping, stream: 0, payload: payload})
      once(:ack, &blk) if blk
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
      send({
        type: :goaway, last_stream: (@streams.max.first rescue 0),
        error: error, payload: payload
      })
      @state = :closed
    end

    # Sends a connection SETTINGS frame to the peer.
    #
    # @param settings [Array or Hash]
    def settings(payload)
      payload = payload.to_a
      @pending_settings << payload
      send({type: :settings, stream: 0, payload: payload})
      @pending_settings << payload
    end

    # Decodes incoming bytes into HTTP 2.0 frames and routes them to
    # appropriate receivers: connection frames are handled directly, and
    # stream frames are passed to appropriate stream objects.
    #
    # @param data [String] Binary encoded string
    def receive(data)
      @recv_buffer << data

      # Upon establishment of a TCP connection and determination that
      # HTTP/2.0 will be used by both peers, each endpoint MUST send a
      # connection header as a final confirmation and to establish the
      # initial settings for the HTTP/2.0 connection.
      #
      # Client connection header is 24 byte connection header followed by
      # SETTINGS frame. Server connection header is SETTINGS frame only.
      if @state == :new
        if @recv_buffer.size < 24
          if !CONNECTION_HEADER.start_with? @recv_buffer
            raise HandshakeError.new
          else
            return
          end

        elsif @recv_buffer.read(24) != CONNECTION_HEADER
          raise HandshakeError.new
        else
          @state = :connection_header
          payload = @settings.select {|k,v| v != SPEC_DEFAULT_CONNECTION_SETTINGS[k]}
          settings(payload)
        end
      end

      while frame = @framer.parse(@recv_buffer) do
        emit(:frame_received, frame)

        # Header blocks MUST be transmitted as a contiguous sequence of frames
        # with no interleaved frames of any other type, or from any other stream.
        if !@continuation.empty?
          if frame[:type]  != :continuation ||
             frame[:stream] != @continuation.first[:stream]
            connection_error
          end

          @continuation << frame
          return if !frame[:flags].include? :end_headers

          payload = @continuation.map {|f| f[:payload]}.join

          frame = @continuation.shift
          @continuation.clear

          frame.delete(:length)
          frame[:payload] = Buffer.new(payload)
          frame[:flags] << :end_headers
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
              stream = activate_stream(id:         frame[:stream],
                                       weight:     frame[:weight]     || DEFAULT_WEIGHT,
                                       dependency: frame[:dependency] || 0,
                                       exclusive:  frame[:exclusive]  || false)
              emit(:stream, stream)
            end

            stream << frame

          when :push_promise
            # The last frame in a sequence of PUSH_PROMISE/CONTINUATION
            # frames MUST have the END_HEADERS flag set
            if !frame[:flags].include? :end_headers
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
                send({type: :rst_stream, stream: pid, error: :refused_stream})
              else
                connection_error
              end
            end

            stream = activate_stream(id: pid, parent: parent)
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

    rescue
      connection_error
    end
    alias :<< :receive

    private

    # Send an outgoing frame. DATA frames are subject to connection flow
    # control and may be split and / or buffered based on current window size.
    # All other frames are sent immediately.
    #
    # @note all frames are currently delivered in FIFO order.
    # @param frame [Hash]
    def send(frame)
      emit(:frame_sent, frame)
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
          # HEADERS and PUSH_PROMISE may generate CONTINUATION
          frames = encode(frame)
          frames.each {|f| emit(:frame, f) }
        end
      end
    end

    # Applies HTTP 2.0 binary encoding to the frame.
    #
    # @param frame [Hash]
    # @return [Array of Buffer] encoded frame
    def encode(frame)
      if frame[:type] == :headers ||
         frame[:type] == :push_promise
        frames = encode_headers(frame) # HEADERS and PUSH_PROMISE may create more than one frame
      else
        frames = [frame]               # otherwise one frame
      end

      frames.map {|f| @framer.generate(f) }
    end

    # Check if frame is a connection frame: SETTINGS, PING, GOAWAY, and any
    # frame addressed to stream ID = 0.
    #
    # @param frame [Hash]
    # @return [Boolean]
    def connection_frame?(frame)
      frame[:stream] == 0 ||
      frame[:type] == :settings ||
      frame[:type] == :ping ||
      frame[:type] == :goaway
    end

    # Process received connection frame (stream ID = 0).
    # - Handle SETTINGS updates
    # - Connection flow control (WINDOW_UPDATE)
    # - Emit PONG auto-reply to PING frames
    # - Mark connection as closed on GOAWAY
    #
    # @param frame [Hash]
    def connection_management(frame)
      case @state
      when :connection_header
        # SETTINGS frames MUST be sent at the start of a connection.
        @state = :connected
        connection_settings(frame)

      when :connected
        case frame[:type]
        when :settings
          connection_settings(frame)
        when :window_update
          @window += frame[:increment]
          send_data(nil, true)
        when :ping
          if frame[:flags].include? :ack
            emit(:ack, frame[:payload])
          else
            send({
              type: :ping, stream: 0,
              flags: [:ack], payload: frame[:payload]
            })
          end
        when :goaway
          # Receivers of a GOAWAY frame MUST NOT open additional streams on
          # the connection, although a new connection can be established
          # for new streams.
          @state = :closed
          emit(:goaway, frame[:last_stream], frame[:error], frame[:payload])
        when :altsvc, :blocked
          emit(frame[:type], frame)
        else
          connection_error
        end
      else
        connection_error
      end
    end

    # Update local connection settings based on parameters set by the peer.
    #
    # @param frame [Hash]
    def connection_settings(frame)
      if (frame[:type] != :settings || frame[:stream] != 0)
        connection_error
      end

      settings, ack_received = \
        if frame[:flags].include?(:ack)
          # Process pending settings we have sent.
          [@pending_settings.shift, true]
        else
          [frame[:payload], false]
        end

      settings.each do |key,v|
        @settings[key] = v
        case key
        when :settings_max_concurrent_streams

        # A change to SETTINGS_INITIAL_WINDOW_SIZE could cause the available
        # space in a flow control window to become negative. A sender MUST
        # track the negative flow control window, and MUST NOT send new flow
        # controlled frames until it receives WINDOW_UPDATE frames that cause
        # the flow control window to become positive.
        when :settings_initial_window_size
          v > 0x7fffffff and connection_error
          @window = @window - @window_limit + v
          @streams.each do |id, stream|
            stream.emit(:window, stream.window - @window_limit + v)
          end

          @window_limit = v

        # Setting header table size might cause some headers evicted
        when :settings_header_table_size
          @compressor.set_table_size(v)

        when :settings_enable_push
          if @stream_id % 2 == 1
            # This is client.  Peer (server) is not allowed to change settings_enable_push.
            unless v == 0
              connection_error
            end
          else
            # This is server.  Peer (client) can set either 0 or 1.
            unless v == 0 || v == 1
              connection_error
            end
          end

        when :settings_max_frame_size
          self.max_frame_size = v

        when :settings_compress_data
          # This is server.  Peer (client) can set either 0 or 1.
          v == 0 || v == 1 or connection_error

        else
          # ignore unknown settings
        end
      end

      if ack_received
        emit(:settings_ack, frame, @pending_settings.size)
      elsif @state != :closed
        # send ack
        send({type: :settings, stream: 0, payload: [], flags: [:ack]})
      end
    end

    # Decode headers payload and update connection decompressor state.
    #
    # The receiver endpoint reassembles the header block by concatenating
    # the individual fragments, then decompresses the block to reconstruct
    # the header set - aka, header payloads are buffered until END_HEADERS,
    # or an END_PROMISE flag is seen.
    #
    # @param frame [Hash]
    def decode_headers(frame)
      if frame[:payload].is_a? String
        frame[:payload] = @decompressor.decode(frame[:payload])
      end

    rescue Exception => e
      connection_error(:compression_error, msg: e.message)
    end

    # Encode headers payload and update connection compressor state.
    #
    # @param frame [Hash]
    # @return [Array of Frame]
    def encode_headers(frame)
      payload = frame[:payload]
      unless payload.is_a? String
        payload = @compressor.encode(payload)
      end

      frames = []

      while payload.size > 0
        cont = frame.dup
        cont[:type] = :continuation
        cont[:flags] = []
        cont[:payload] = payload.slice!(0, max_frame_size)
        frames << cont
      end
      if frames.empty?
        frames = [frame]
      else
        frames.first[:type]  = frame[:type]
        frames.first[:flags] = frame[:flags] - [:end_headers]
        frames.last[:flags]  << :end_headers
      end

      frames

    rescue Exception => e
      [connection_error(:compression_error, msg: e.message)]
    end

    # Activates new incoming or outgoing stream and registers appropriate
    # connection managemet callbacks.
    #
    # @param id [Integer]
    # @param priority [Integer]
    # @param window [Integer]
    # @param parent [Stream]
    def activate_stream(id: nil, **args)
      if @streams.key?(id)
        connection_error(msg: 'Stream ID already exists')
      end

      stream = Stream.new({connection: self, id: id, window: @window_limit}.merge(args))

      # Streams that are in the "open" state, or either of the "half closed"
      # states count toward the maximum number of streams that an endpoint is
      # permitted to open.
      stream.once(:active) { @active_stream_count += 1 }
      stream.once(:close)  { @active_stream_count -= 1 }
      stream.on(:promise, &method(:promise)) if self.is_a? Server
      stream.on(:frame,   &method(:send))

      @streams[id] = stream
    end

    # Emit GOAWAY error indicating to peer that the connection is being
    # aborted, and once sent, raise a local exception.
    #
    # @param error [Symbol]
    # @option error [Symbol] :no_error
    # @option error [Symbol] :internal_error
    # @option error [Symbol] :flow_control_error
    # @option error [Symbol] :stream_closed
    # @option error [Symbol] :frame_too_large
    # @option error [Symbol] :compression_error
    # @param msg [String]
    def connection_error(error = :protocol_error, msg: nil)
      goaway(error) if @state != :closed && @state != :new

      @state, @error = :closed, error
      klass = error.to_s.split('_').map(&:capitalize).join
      raise Error.const_get(klass).new(msg)
    end

  end
end
