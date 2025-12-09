# frozen_string_literal: true

module HTTP2
  # Default connection and stream flow control window (64KB).
  DEFAULT_FLOW_WINDOW = 65_535

  # Default header table size
  DEFAULT_HEADER_SIZE = 4096

  # Default stream_limit
  DEFAULT_MAX_CONCURRENT_STREAMS = 100

  # Default values for SETTINGS frame, as defined by the spec.
  SPEC_DEFAULT_CONNECTION_SETTINGS = {
    settings_header_table_size: 4096,
    settings_enable_push: 1, # enabled for servers
    settings_max_concurrent_streams: Framer::MAX_STREAM_ID, # unlimited
    settings_initial_window_size: 65_535,
    settings_max_frame_size: 16_384,
    settings_max_header_list_size: (2 << 30) - 1 # unlimited
  }.freeze

  DEFAULT_CONNECTION_SETTINGS = {
    settings_header_table_size: 4096,
    settings_enable_push: 1, # enabled for servers
    settings_max_concurrent_streams: 100,
    settings_initial_window_size: 65_535,
    settings_max_frame_size: 16_384,
    settings_max_header_list_size: (2 << 30) - 1 # unlimited
  }.freeze

  # Default stream priority (lower values are higher priority).
  DEFAULT_WEIGHT = 16

  # Default connection "fast-fail" preamble string as defined by the spec.
  CONNECTION_PREFACE_MAGIC = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  REQUEST_MANDATORY_HEADERS = %w[:scheme :method :authority :path].freeze

  RESPONSE_MANDATORY_HEADERS = %w[:status].freeze

  CONNECTION_FRAME_TYPES = %i[settings ping goaway].freeze

  HEADERS_FRAME_TYPES = %i[headers push_promise].freeze

  STREAM_OPEN_STATES = %i[open half_closed_local].freeze

  # Connection encapsulates all of the connection, stream, flow-control,
  # error management, and other processing logic required for a well-behaved
  # HTTP 2.0 endpoint.
  #
  # Note that this class should not be used directly. Instead, you want to
  # use either Client or Server class to drive the HTTP 2.0 exchange.
  #
  class Connection
    include FlowBuffer
    include Emitter
    include Error
    include BufferUtils

    # Connection state (:new, :closed).
    attr_reader :state

    # Size of current connection flow control window (by default, set to
    # infinity, but is automatically updated on receipt of peer settings).
    attr_reader :local_window
    attr_reader :remote_window, :remote_settings
    alias window local_window

    # Current settings value for local and peer
    attr_reader :local_settings

    # Pending settings value
    #  Sent but not ack'ed settings
    attr_reader :pending_settings

    # Number of active streams between client and server (reserved streams
    # are not counted towards the stream limit).
    attr_accessor :active_stream_count

    # Initializes new connection object.
    #
    def initialize(settings = {})
      @local_settings  = DEFAULT_CONNECTION_SETTINGS.merge(settings)
      @remote_settings = SPEC_DEFAULT_CONNECTION_SETTINGS.dup

      @compressor   = Header::Compressor.new(settings)
      @decompressor = Header::Decompressor.new(settings)

      @active_stream_count = 0
      @last_stream_id = 0
      @streams = {}
      @streams_recently_closed = {}
      @pending_settings = []

      @framer = Framer.new(@local_settings[:settings_max_frame_size])

      @local_window_limit = @local_settings[:settings_initial_window_size]
      @local_window = @local_window_limit
      @remote_window_limit = @remote_settings[:settings_initial_window_size]
      @remote_window = @remote_window_limit

      @recv_buffer = "".b
      @continuation = []
      @error = nil

      @h2c_upgrade = nil
      @closed_since = nil
      @received_frame = false

      # from mixins
      @listeners = Hash.new { |hash, key| hash[key] = [] }
      @send_buffer = FrameBuffer.new
    end

    def closed?
      @state == :closed
    end

    # Allocates new stream for current connection.
    #
    # @param priority [Integer]
    # @param window [Integer]
    # @param parent [Stream]
    def new_stream(**args)
      raise ConnectionClosed if @state == :closed
      raise StreamLimitExceeded if @active_stream_count >= @remote_settings[:settings_max_concurrent_streams]

      connection_error(:protocol_error, msg: "id is smaller than previous") if @stream_id < @last_stream_id

      stream = activate_stream(id: @stream_id, **args)
      @last_stream_id = stream.id

      @stream_id += 2

      stream
    end

    # Sends PING frame to the peer.
    #
    # @param payload [String] optional payload must be 8 bytes long
    # @param blk [Proc] callback to execute when PONG is received
    def ping(payload, &blk)
      send(type: :ping, stream: 0, payload: payload)
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
      send(type: :goaway, last_stream: @last_stream_id,
           error: error, payload: payload)
      @state = :closed
      @closed_since = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Sends a WINDOW_UPDATE frame to the peer.
    #
    # @param increment [Integer]
    def window_update(increment)
      @local_window += increment
      send(type: :window_update, stream: 0, increment: increment)
    end

    # Sends a connection SETTINGS frame to the peer.
    # The values are reflected when the corresponding ACK is received.
    #
    # @param settings [Array or Hash]
    def settings(payload)
      validate_settings(@local_role, payload)
      @pending_settings << payload
      send(type: :settings, stream: 0, payload: payload)
      @pending_settings << payload
    end

    # Decodes incoming bytes into HTTP 2.0 frames and routes them to
    # appropriate receivers: connection frames are handled directly, and
    # stream frames are passed to appropriate stream objects.
    #
    # @param data [String] Binary encoded string
    def receive(data)
      append_str(@recv_buffer, data)

      # Upon establishment of a TCP connection and determination that
      # HTTP/2.0 will be used by both peers, each endpoint MUST send a
      # connection header as a final confirmation and to establish the
      # initial settings for the HTTP/2.0 connection.
      #
      # Client connection header is 24 byte connection header followed by
      # SETTINGS frame. Server connection header is SETTINGS frame only.
      if @state == :waiting_magic
        if @recv_buffer.size < 24
          raise HandshakeError unless CONNECTION_PREFACE_MAGIC.start_with? @recv_buffer

          return # maybe next time
        elsif read_str(@recv_buffer, 24) == CONNECTION_PREFACE_MAGIC
          # MAGIC is OK.  Send our settings
          @state = :waiting_connection_preface
          payload = @local_settings.reject { |k, v| v == SPEC_DEFAULT_CONNECTION_SETTINGS[k] }
          settings(payload)
        else
          raise HandshakeError
        end
      end

      while (frame = @framer.parse(@recv_buffer))
        # @type var stream_id: Integer
        stream_id = frame[:stream]
        frame_type = frame[:type]

        if is_a?(Client) && !@received_frame
          connection_error(:protocol_error, msg: "didn't receive settings") if frame_type != :settings
          @received_frame = true
        end

        # Implementations MUST discard frames
        # that have unknown or unsupported types.
        if frame_type.nil?
          # However, extension frames that appear in
          # the middle of a header block (Section 4.3) are not permitted; these
          # MUST be treated as a connection error (Section 5.4.1) of type
          # PROTOCOL_ERROR.
          connection_error(:protocol_error) unless @continuation.empty?
          next
        end

        emit(:frame_received, frame)

        # Header blocks MUST be transmitted as a contiguous sequence of frames
        # with no interleaved frames of any other type, or from any other stream.
        unless @continuation.empty?
          connection_error unless frame_type == :continuation && stream_id == @continuation.first[:stream]

          @continuation << frame
          unless frame[:flags].include? :end_headers
            buffered_payload = @continuation.sum { |f| f[:payload].bytesize }
            # prevent HTTP/2 CONTINUATION FLOOD
            # same heuristic as the one from HAProxy: https://www.haproxy.com/blog/haproxy-is-resilient-to-the-http-2-continuation-flood
            # different mitigation (connection closed, instead of 400 response)
            unless buffered_payload < @local_settings[:settings_max_frame_size]
              connection_error(:protocol_error,
                               msg: "too many continuations received")
            end

            next
          end

          payload = @continuation.map { |f| f[:payload] }.join

          frame = @continuation.shift
          frame_type = frame[:type]

          @continuation.clear

          frame.delete(:length)
          frame[:payload] = payload
          frame[:flags] << :end_headers
        end

        # SETTINGS frames always apply to a connection, never a single stream.
        # The stream identifier for a settings frame MUST be zero.  If an
        # endpoint receives a SETTINGS frame whose stream identifier field is
        # anything other than 0x0, the endpoint MUST respond with a connection
        # error (Section 5.4.1) of type PROTOCOL_ERROR.
        if connection_frame?(frame)
          connection_error(:protocol_error) unless stream_id.zero?
          connection_management(frame)
        else
          case frame_type
          when :headers
            # When server receives even-numbered stream identifier,
            # the endpoint MUST respond with a connection error of type PROTOCOL_ERROR.
            connection_error if stream_id.even? && is_a?(Server)

            # The last frame in a sequence of HEADERS/CONTINUATION
            # frames MUST have the END_HEADERS flag set.
            unless frame[:flags].include? :end_headers
              @continuation << frame
              next
            end

            # After sending a GOAWAY frame, the sender can discard frames
            # for new streams.  However, any frames that alter connection
            # state cannot be completely ignored.  For instance, HEADERS,
            # PUSH_PROMISE and CONTINUATION frames MUST be minimally
            # processed to ensure a consistent compression state
            decode_headers(frame)
            return if @state == :closed

            stream = @streams[stream_id]
            if stream.nil?
              verify_pseudo_headers(frame)

              verify_stream_order(stream_id)
              stream = activate_stream(
                id: stream_id,
                weight: frame[:weight] || DEFAULT_WEIGHT,
                dependency: frame[:dependency] || 0,
                exclusive: frame[:exclusive] || false
              )
              emit(:stream, stream)
            end

            stream << frame

          when :push_promise
            # The last frame in a sequence of PUSH_PROMISE/CONTINUATION
            # frames MUST have the END_HEADERS flag set
            unless frame[:flags].include? :end_headers
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
            parent = @streams[stream_id]
            pid = frame[:promise_stream]

            # if PUSH parent is recently closed, RST_STREAM the push
            if @streams_recently_closed[stream_id]
              send(type: :rst_stream, stream: pid, error: :refused_stream)
              return
            end

            connection_error(msg: "missing parent ID") if parent.nil?

            unless STREAM_OPEN_STATES.include?(parent.state)
              # An endpoint might receive a PUSH_PROMISE frame after it sends
              # RST_STREAM.  PUSH_PROMISE causes a stream to become "reserved".
              # The RST_STREAM does not cancel any promised stream.  Therefore, if
              # promised streams are not desired, a RST_STREAM can be used to
              # close any of those streams.
              if parent.closed == :local_rst
                # We can either (a) 'resurrect' the parent, or (b) RST_STREAM
                # ... sticking with (b), might need to revisit later.
                send(type: :rst_stream, stream: pid, error: :refused_stream)
              else
                connection_error
              end
            end

            _verify_pseudo_headers(frame, REQUEST_MANDATORY_HEADERS)
            verify_stream_order(pid)
            stream = activate_stream(id: pid, parent: parent)
            emit(:promise, stream)
            stream << frame
          else
            if (stream = @streams[stream_id])
              stream << frame
              if frame_type == :data
                update_local_window(frame)
                calculate_window_update(@local_window_limit)
              end
            else
              case frame_type
              # The PRIORITY frame can be sent for a stream in the "idle" or
              # "closed" state. This allows for the reprioritization of a
              # group of dependent streams by altering the priority of an
              # unused or closed parent stream.
              when :priority
                stream = activate_stream(
                  id: stream_id,
                  weight: frame[:weight] || DEFAULT_WEIGHT,
                  dependency: frame[:dependency] || 0,
                  exclusive: frame[:exclusive] || false
                )

                emit(:stream, stream)
                stream << frame

              # WINDOW_UPDATE can be sent by a peer that has sent a frame
              # bearing the END_STREAM flag. This means that a receiver could
              # receive a WINDOW_UPDATE frame on a "half-closed (remote)" or
              # "closed" stream. A receiver MUST NOT treat this as an error
              # (see Section 5.1).
              when :window_update
                unless @streams_recently_closed.key?(stream_id)
                  connection_error(:protocol_error, msg: "sent window update on idle stream")
                end
                stream = @streams_recently_closed[stream_id]
                process_window_update(frame: frame, encode: true)
              # Endpoints MUST ignore
              # WINDOW_UPDATE or RST_STREAM frames received in this state (closed), though
              # endpoints MAY choose to treat frames that arrive a significant
              # time after sending END_STREAM as a connection error.
              when :rst_stream
                unless @streams_recently_closed.key?(stream_id)
                  connection_error(:protocol_error, msg: "sent window update on idle stream")
                end
              else
                # An endpoint that receives an unexpected stream identifier
                # MUST respond with a connection error of type PROTOCOL_ERROR.
                connection_error(msg: "stream does not exist")
              end
            end
          end
        end
      end
    rescue StandardError => e
      raise if e.is_a?(Error::Error)

      connection_error(e: e)
    end

    def <<(data)
      receive(data)
    end

    private

    # Send an outgoing frame. DATA frames are subject to connection flow
    # control and may be split and / or buffered based on current window size.
    # All other frames are sent immediately.
    #
    # @note all frames are currently delivered in FIFO order.
    # @param frame [Hash]
    def send(frame)
      frame_type = frame[:type]

      emit(:frame_sent, frame)
      if frame_type == :data
        send_data(frame, true)

      elsif frame_type == :rst_stream && frame[:error] == :protocol_error
        # An endpoint can end a connection at any time. In particular, an
        # endpoint MAY choose to treat a stream error as a connection error.

        goaway(:protocol_error)
      else
        # HEADERS and PUSH_PROMISE may generate CONTINUATION. Also send
        # RST_STREAM that are not protocol errors
        encode(frame)
      end
    end

    # Applies HTTP 2.0 binary encoding to the frame.
    #
    # @param frame [Hash]
    def encode(frame)
      if HEADERS_FRAME_TYPES.include?(frame[:type])
        encode_headers(frame) # HEADERS and PUSH_PROMISE may create more than one frame
      else
        emit(:frame, @framer.generate(frame))
      end
    end

    # Check if frame is a connection frame: SETTINGS, PING, GOAWAY, and any
    # frame addressed to stream ID = 0.
    #
    # @param frame [Hash]
    # @return [Boolean]
    def connection_frame?(frame)
      frame[:stream].zero? || CONNECTION_FRAME_TYPES.include?(frame[:type])
    end

    # Process received connection frame (stream ID = 0).
    # - Handle SETTINGS updates
    # - Connection flow control (WINDOW_UPDATE)
    # - Emit PONG auto-reply to PING frames
    # - Mark connection as closed on GOAWAY
    #
    # @param frame [Hash]
    def connection_management(frame)
      frame_type = frame[:type]

      case @state
      when :waiting_connection_preface
        # The first frame MUST be a SETTINGS frame at the start of a connection.
        connection_error unless frame[:type] == :settings

        @state = :connected
        connection_settings(frame)

      when :connected
        case frame_type
        when :settings
          connection_settings(frame)
        when :window_update
          process_window_update(frame: frame, encode: true)
        when :ping
          ping_management(frame)
        when :goaway
          # Receivers of a GOAWAY frame MUST NOT open additional streams on
          # the connection, although a new connection can be established
          # for new streams.
          @state = :closed
          @closed_since = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          emit(:goaway, frame[:last_stream], frame[:error], frame[:payload])
        when :altsvc
          origin = frame[:origin]
          # 4.  The ALTSVC HTTP/2 Frame
          # An ALTSVC frame on stream 0 with empty (length 0) "Origin"
          # information is invalid and MUST be ignored.
          emit(:altsvc, frame) if origin && !origin.empty?
        when :origin
          return if @h2c_upgrade || !frame[:flags].empty?

          frame[:payload].each do |orig|
            emit(:origin, orig)
          end
        when :blocked
          emit(:blocked, frame)
        else
          connection_error
        end
      when :closed
        case frame_type
        when :goaway
          #  6.8. GOAWAY
          # An endpoint MAY send multiple GOAWAY frames if circumstances change.
        when :ping
          ping_management(frame)
        else
          connection_error if (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @closed_since) > 15
        end
      else
        connection_error
      end
    end

    def ping_management(frame)
      if frame[:flags].include? :ack
        emit(:ack, frame[:payload])
      else
        send(type: :ping, stream: 0,
             flags: [:ack], payload: frame[:payload])
      end
    end

    # Validate settings parameters.  See sepc Section 6.5.2.
    #
    # @param role [Symbol] The sender's role: :client or :server
    # @return nil if no error.  Exception object in case of any error.
    def validate_settings(role, settings)
      settings.each do |key, v|
        case key
        when :settings_enable_push
          case role
          when :server
            # Section 8.2
            # Clients MUST reject any attempt to change the
            # SETTINGS_ENABLE_PUSH setting to a value other than 0 by treating the
            # message as a connection error (Section 5.4.1) of type PROTOCOL_ERROR.
            next if v.zero?

            connection_error(:protocol_error, msg: "invalid #{key} value")
          when :client
            # Any value other than 0 or 1 MUST be treated as a
            # connection error (Section 5.4.1) of type PROTOCOL_ERROR.
            next if v.zero? || v == 1

            connection_error(:protocol_error, msg: "invalid #{key} value")
          end
        when :settings_initial_window_size
          # Values above the maximum flow control window size of 2^31-1 MUST
          # be treated as a connection error (Section 5.4.1) of type
          # FLOW_CONTROL_ERROR.
          next if v <= 0x7fffffff

          connection_error(:flow_control_error, msg: "invalid #{key} value")
        when :settings_max_frame_size
          # The initial value is 2^14 (16,384) octets.  The value advertised
          # by an endpoint MUST be between this initial value and the maximum
          # allowed frame size (2^24-1 or 16,777,215 octets), inclusive.
          # Values outside this range MUST be treated as a connection error
          # (Section 5.4.1) of type PROTOCOL_ERROR.
          next if v.between?(16_384, 16_777_215)

          connection_error(:protocol_error, msg: "invalid #{key} value")
          # when :settings_max_concurrent_streams
          # Any value is valid
          # when :settings_header_table_size
          # Any value is valid
          # when :settings_max_header_list_size
          # Any value is valid
          # else # ignore unknown settings
        end
      end
    end

    # Update connection settings based on parameters set by the peer.
    #
    # @param frame [Hash]
    def connection_settings(frame)
      # Apply settings.
      #  side =
      #   local: previously sent and pended our settings should be effective
      #   remote: just received peer settings should immediately be effective
      if frame[:flags].include?(:ack)
        # Process pending settings we have sent.
        settings = @pending_settings.shift
        side = :local
      else
        validate_settings(@remote_role, frame[:payload])
        settings = frame[:payload]
        side = :remote
      end

      settings.each do |key, v|
        case side
        when :local
          @local_settings[key] = v
        when :remote
          @remote_settings[key] = v
        end

        case key
        when :settings_max_concurrent_streams
          # Do nothing.
          # The value controls at the next attempt of stream creation.

        when :settings_initial_window_size
          # A change to SETTINGS_INITIAL_WINDOW_SIZE could cause the available
          # space in a flow control window to become negative. A sender MUST
          # track the negative flow control window, and MUST NOT send new flow
          # controlled frames until it receives WINDOW_UPDATE frames that cause
          # the flow control window to become positive.
          case side
          when :local
            @local_window = @local_window - @local_window_limit + v
            @streams.each_value do |stream|
              stream.emit(:local_window, stream.local_window - @local_window_limit + v)
            end

            @local_window_limit = v
          when :remote
            # can adjust the initial window size for new streams by including a
            # value for SETTINGS_INITIAL_WINDOW_SIZE in the SETTINGS frame.
            # The connection flow-control window can only be changed using
            # WINDOW_UPDATE frames.
            @streams.each_value do |stream|
              # Event name is :window, not :remote_window
              stream.emit(:window, stream.remote_window - @remote_window_limit + v)
            end

            @remote_window_limit = v
          end

        when :settings_header_table_size
          # Setting header table size might cause some headers evicted
          case side
          when :local
            @compressor.table_size = v
          when :remote
            @decompressor.table_size = v
          end

        when :settings_enable_push
          # nothing to do

        when :settings_max_frame_size
          @framer.remote_max_frame_size = v

          # else # ignore unknown settings
        end
      end

      case side
      when :local
        # Received a settings_ack.  Notify application layer.
        emit(:settings_ack, frame, @pending_settings.size)
      when :remote
        unless @state == :closed || @h2c_upgrade == :start
          # Send ack to peer
          send(type: :settings, stream: 0, payload: [], flags: [:ack])
          # when initial window size changes, we try to flush any buffered
          # data.
          @streams.each_value(&:flush)
        end
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
      frame[:payload] = @decompressor.decode(frame[:payload], frame) if frame[:payload].is_a?(String)
    rescue CompressionError => e
      connection_error(:compression_error, e: e)
    rescue ProtocolError => e
      connection_error(:protocol_error, e: e)
    rescue StandardError => e
      connection_error(:internal_error, e: e)
    end

    # Encode headers payload and update connection compressor state.
    #
    # @param headers_frame [Hash]
    def encode_headers(headers_frame)
      payload = headers_frame[:payload]
      begin
        payload = headers_frame[:payload] = @compressor.encode(payload) unless payload.is_a?(String)
      rescue StandardError => e
        connection_error(:compression_error, e: e)
      end

      max_frame_size = @remote_settings[:settings_max_frame_size]

      # if single frame, return immediately
      if payload.bytesize <= max_frame_size
        emit(:frame, @framer.generate(headers_frame))
        return
      end

      # split into multiple CONTINUATION frames
      headers_frame[:flags].delete(:end_headers)
      headers_frame[:payload] = payload.byteslice(0, max_frame_size)
      payload = payload.byteslice(max_frame_size..-1)

      # emit first HEADERS frame
      emit(:frame, @framer.generate(headers_frame))

      loop do
        continuation_frame = headers_frame.merge(
          type: :continuation,
          flags: EMPTY,
          payload: payload.byteslice(0, max_frame_size)
        )

        payload = payload.byteslice(max_frame_size..-1)

        if payload.nil? || payload.empty?
          continuation_frame[:flags] = [:end_headers]
          emit(:frame, @framer.generate(continuation_frame))
          break
        end

        emit(:frame, @framer.generate(continuation_frame))
      end
    end

    # Activates new incoming or outgoing stream and registers appropriate
    # connection managemet callbacks.
    #
    # @param id [Integer]
    # @param priority [Integer]
    # @param window [Integer]
    # @param parent [Stream]
    def activate_stream(id:, **args)
      connection_error(msg: "Stream ID already exists") if @streams.key?(id)

      raise StreamLimitExceeded if @active_stream_count >= @local_settings[:settings_max_concurrent_streams]

      stream = Stream.new(connection: self, id: id, **args)

      stream.once(:close) do
        @streams.delete(id)

        # Store a reference to the closed stream, such that we can respond
        # to any in-flight frames while close is registered on both sides.
        # References to such streams will be purged whenever another stream
        # is closed, with a minimum of 15s RTT time window.
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        _, closed_since = @streams_recently_closed.first

        # forego recently closed recycling if empty or the first element
        # hasn't expired yet (it's ordered).
        if closed_since && (now - closed_since) > 15
          # discards all streams which have closed for a while.
          # TODO: use a drop_while! variant whenever there is one.
          @streams_recently_closed = @streams_recently_closed.drop_while do |_, since|
            (now - since) > 15
          end.to_h
        end

        @streams_recently_closed[id] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      stream.on(:frame, &method(:send))
      @streams[id] = stream
    end

    def verify_stream_order(id)
      return unless id.odd?

      connection_error(msg: "Stream ID smaller than previous") if @last_stream_id >= id
      @last_stream_id = id
    end

    def _verify_pseudo_headers(frame, mandatory_headers)
      headers = frame[:payload]
      return if headers.is_a?(String)

      pseudo_headers = headers.take_while do |field, value|
        # use this loop to validate pseudo-headers
        connection_error(:protocol_error, msg: "path is empty") if field == ":path" && value.empty?
        field.start_with?(":")
      end.map(&:first)
      return if mandatory_headers.size == pseudo_headers.size &&
                (mandatory_headers - pseudo_headers).empty?

      connection_error(:protocol_error, msg: "invalid pseudo-headers")
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
    def connection_error(error = :protocol_error, msg: nil, e: nil)
      goaway(error) unless @state == :closed || @state == :new

      @state = :closed
      @error = error
      msg ||= e ? e.message : "protocol error"
      backtrace = e ? e.backtrace : nil
      raise Error.types[error], msg, backtrace
    end
    alias error connection_error

    def manage_state(_)
      yield
    end
  end
end
