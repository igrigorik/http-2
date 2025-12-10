# frozen_string_literal: true

module HTTP2
  # Performs encoding, decoding, and validation of binary HTTP/2 frames.
  #
  class Framer
    include Error
    include PackingExtensions
    include BufferUtils

    # Default value of max frame size (16384 bytes)
    DEFAULT_MAX_FRAME_SIZE = 2 << 13

    # maximum frame size
    attr_accessor :local_max_frame_size, :remote_max_frame_size

    # Maximum stream ID (2^31)
    MAX_STREAM_ID = 0x7fffffff

    # Maximum window increment value (2^31)
    MAX_WINDOWINC = 0x7fffffff

    # HTTP/2 frame type mapping as defined by the spec
    FRAME_TYPES = {
      data: 0x0,
      headers: 0x1,
      priority: 0x2,
      rst_stream: 0x3,
      settings: 0x4,
      push_promise: 0x5,
      ping: 0x6,
      goaway: 0x7,
      window_update: 0x8,
      continuation: 0x9,
      altsvc: 0xa,
      origin: 0xc
    }.freeze

    FRAME_TYPES_BY_NAME = FRAME_TYPES.invert.freeze

    FRAME_TYPES_WITH_PADDING = %i[data headers push_promise].freeze

    # Per frame flags as defined by the spec
    FRAME_FLAGS = {
      data: {
        end_stream: 0,
        padded: 3,
        compressed: 5
      },
      headers: {
        end_stream: 0,
        end_headers: 2,
        padded: 3,
        priority: 5
      },
      priority: {},
      rst_stream: {},
      settings: { ack: 0 },
      push_promise: {
        end_headers: 2,
        padded: 3
      },
      ping: { ack: 0 },
      goaway: {},
      window_update: {},
      continuation: { end_headers: 2 },
      altsvc: {},
      origin: {
        reserved: 1,
        reserved2: 2,
        reserved3: 4,
        reserved4: 8
      }
    }.each_value(&:freeze).freeze

    # Default settings as defined by the spec
    DEFINED_SETTINGS = {
      settings_header_table_size: 1,
      settings_enable_push: 2,
      settings_max_concurrent_streams: 3,
      settings_initial_window_size: 4,
      settings_max_frame_size: 5,
      settings_max_header_list_size: 6
    }.freeze

    # Default error types as defined by the spec
    DEFINED_ERRORS = {
      no_error: 0,
      protocol_error: 1,
      internal_error: 2,
      flow_control_error: 3,
      settings_timeout: 4,
      stream_closed: 5,
      frame_size_error: 6,
      refused_stream: 7,
      cancel: 8,
      compression_error: 9,
      connect_error: 10,
      enhance_your_calm: 11,
      inadequate_security: 12,
      http_1_1_required: 13
    }.freeze

    RBIT  = 0x7fffffff
    RBYTE = 0x0fffffff
    EBIT  = 0x80000000
    UINT32 = "N"
    UINT16 = "n"
    UINT8  = "C"
    HEADERPACK = (UINT8 + UINT16 + UINT8 + UINT8 + UINT32).freeze
    FRAME_LENGTH_HISHIFT = 16
    FRAME_LENGTH_LOMASK  = 0xFFFF

    private_constant :RBIT, :RBYTE, :EBIT, :HEADERPACK, :UINT32, :UINT16, :UINT8

    # Initializes new framer object.
    #
    def initialize(local_max_frame_size = DEFAULT_MAX_FRAME_SIZE,
                   remote_max_frame_size = DEFAULT_MAX_FRAME_SIZE)
      @local_max_frame_size = local_max_frame_size
      @remote_max_frame_size = remote_max_frame_size
      @frames = []
    end

    # Generates common 9-byte frame header.
    # - http://tools.ietf.org/html/draft-ietf-httpbis-http2-16#section-4.1
    #
    # @param frame [Hash]
    # @param buffer [String] buffer to pack bytes into
    # @return [String]
    def common_header(frame, buffer:)
      type = frame[:type]

      raise CompressionError, "Invalid frame type (#{type})" unless FRAME_TYPES[type]

      length = frame[:length]

      raise CompressionError, "Frame size is too large: #{length}" if length > @remote_max_frame_size

      raise CompressionError, "Frame size is invalid: #{length}" if length < 0

      stream_id = frame.fetch(:stream, 0)

      raise CompressionError, "Stream ID (#{stream_id}) is too large" if stream_id > MAX_STREAM_ID

      if type == :window_update && frame[:increment] > MAX_WINDOWINC
        raise CompressionError, "Window increment (#{frame[:increment]}) is too large"
      end

      header = buffer

      # make sure the buffer is binary and unfrozen
      if buffer.frozen?
        header = String.new("", encoding: Encoding::BINARY, capacity: buffer.bytesize + 9) # header length
        append_str(header, buffer)
      else
        header.force_encoding(Encoding::BINARY)
      end

      pack([
             (length >> FRAME_LENGTH_HISHIFT),
             (length & FRAME_LENGTH_LOMASK),
             FRAME_TYPES[type],
             frame[:flags].reduce(0) do |acc, f|
               position = FRAME_FLAGS[type][f]
               raise CompressionError, "Invalid frame flag (#{f}) for #{type}" unless position

               acc | (1 << position)
             end,
             stream_id
           ], HEADERPACK, buffer: header, offset: 0) # 8+16,8,8,32
    end

    # Decodes common 9-byte header.
    #
    # @param buf [Buffer]
    # @return [Hash] the corresponding frame
    def read_common_header(buf)
      len_hi, len_lo, type, flags, stream = buf.byteslice(0, 9).unpack(HEADERPACK)

      type = FRAME_TYPES_BY_NAME[type]
      length = (len_hi << FRAME_LENGTH_HISHIFT) | len_lo

      return { length: length } unless type

      {
        type: type,
        flags: FRAME_FLAGS[type].filter_map do |name, pos|
          name if flags.anybits?(1 << pos)
        end,
        length: length,
        stream: stream & RBIT
      }
    end

    # Generates encoded HTTP/2 frame.
    # - http://tools.ietf.org/html/draft-ietf-httpbis-http2
    #
    # @param frame [Hash]
    def generate(frame)
      length = 0
      frame[:flags] ||= EMPTY

      case frame[:type]
      when :data, :continuation
        bytes = frame[:payload]
        length = bytes.bytesize

      when :headers
        headers = frame[:payload]

        if frame[:weight] || frame[:dependency] || !frame[:exclusive].nil?
          unless frame[:weight] && frame[:dependency] && !frame[:exclusive].nil?
            raise CompressionError, "Must specify all of priority parameters for #{frame[:type]}"
          end

          frame[:flags] += [:priority] unless frame[:flags].include?(:priority)
        end

        if frame[:flags].include?(:priority)
          length = 5 + headers.bytesize
          bytes = String.new("", encoding: Encoding::BINARY, capacity: length)
          pack([(frame[:exclusive] ? EBIT : 0) | (frame[:dependency] & RBIT)], UINT32, buffer: bytes)
          pack([frame[:weight] - 1], UINT8, buffer: bytes)
          append_str(bytes, headers)
        else
          length = headers.bytesize
          bytes = headers
        end

      when :priority
        unless frame[:weight] && frame[:dependency] && !frame[:exclusive].nil?
          raise CompressionError, "Must specify all of priority parameters for #{frame[:type]}"
        end

        length = 5
        bytes = String.new("", encoding: Encoding::BINARY, capacity: length)
        pack([(frame[:exclusive] ? EBIT : 0) | (frame[:dependency] & RBIT)], UINT32, buffer: bytes)
        pack([frame[:weight] - 1], UINT8, buffer: bytes)

      when :rst_stream
        length = 4
        bytes = String.new("", encoding: Encoding::BINARY, capacity: length)
        pack_error(frame[:error], buffer: bytes)

      when :settings
        if (stream_id = frame[:stream]) && stream_id.nonzero?
          raise CompressionError, "Invalid stream ID (#{stream_id})"
        end

        settings = frame[:payload]
        bytes = String.new("", encoding: Encoding::BINARY, capacity: length)

        settings.each do |(k, v)|
          if k.is_a? Integer # rubocop:disable Style/GuardClause
            DEFINED_SETTINGS.value?(k) || next
          else
            k = DEFINED_SETTINGS[k]

            raise CompressionError, "Unknown settings ID for #{k}" if k.nil?
          end

          pack([k], UINT16, buffer: bytes)
          pack([v], UINT32, buffer: bytes)
          length += 6
        end

      when :push_promise
        length = 4 + frame[:payload].bytesize
        bytes = String.new("", encoding: Encoding::BINARY, capacity: length)
        pack([frame[:promise_stream] & RBIT], UINT32, buffer: bytes)
        append_str(bytes, frame[:payload])

      when :ping
        bytes = frame[:payload].b
        raise CompressionError, "Invalid payload size (#{bytes.size} != 8 bytes)" if bytes.bytesize != 8

        length = 8

      when :goaway
        data = frame[:payload]
        length = 8
        length += data.bytesize if data
        bytes = String.new("", encoding: Encoding::BINARY, capacity: length)

        pack([frame[:last_stream] & RBIT], UINT32, buffer: bytes)
        pack_error(frame[:error], buffer: bytes)

        append_str(bytes, data) if data

      when :window_update
        length = 4
        bytes = String.new("", encoding: Encoding::BINARY, capacity: length)
        pack([frame[:increment] & RBIT], UINT32, buffer: bytes)

      when :altsvc
        length = 6
        bytes = String.new("", encoding: Encoding::BINARY, capacity: length)
        pack([frame[:max_age], frame[:port]], UINT32 + UINT16, buffer: bytes)
        if frame[:proto]
          raise CompressionError, "Proto too long" if frame[:proto].bytesize > 255

          pack([frame[:proto].bytesize], UINT8, buffer: bytes)
          append_str(bytes, frame[:proto])
          length += 1 + frame[:proto].bytesize
        else
          pack([0], UINT8, buffer: bytes)
          length += 1
        end
        if frame[:host]
          raise CompressionError, "Host too long" if frame[:host].bytesize > 255

          pack([frame[:host].bytesize], UINT8, buffer: bytes)
          append_str(bytes, frame[:host])
          length += 1 + frame[:host].bytesize
        else
          pack([0], UINT8, buffer: bytes)
          length += 1
        end
        if frame[:origin]
          append_str(bytes, frame[:origin])
          length += frame[:origin].bytesize
        end

      when :origin
        origins = frame[:payload]
        length = origins.sum(&:bytesize) + (2 * origins.size)
        bytes = String.new("", encoding: Encoding::BINARY, capacity: length)
        origins.each do |origin|
          pack([origin.bytesize], UINT16, buffer: bytes)
          append_str(bytes, origin)
        end
      end

      # Process padding.
      #  frame[:padding] gives number of extra octets to be added.
      # - http://tools.ietf.org/html/draft-ietf-httpbis-http2-16#section-6.1
      if frame[:padding]
        unless FRAME_TYPES_WITH_PADDING.include?(frame[:type])
          raise CompressionError, "Invalid padding flag for #{frame[:type]}"
        end

        padlen = frame[:padding]

        if padlen <= 0 || padlen > 256 || padlen + length > @remote_max_frame_size
          raise CompressionError, "Invalid padding #{padlen}"
        end

        # make sure the buffer is binary and unfrozen
        if bytes.frozen?
          bytes = bytes.b
        else
          bytes.force_encoding(Encoding::BINARY)
        end

        length += padlen
        pack([padlen -= 1], UINT8, buffer: bytes, offset: 0)
        frame[:flags] += [:padded]

        # Padding:  Padding octets that contain no application semantic value.
        # Padding octets MUST be set to zero when sending and ignored when
        # receiving.
        append_str(bytes, "\0" * padlen)
      end

      frame[:length] = length
      common_header(frame, buffer: bytes)
    end

    # Decodes complete HTTP/2 frame from provided buffer. If the buffer
    # does not contain enough data, no further work is performed.
    #
    # @param buf [Buffer]
    def parse(buf)
      while (frame = decode_frame(buf))
        if frame[:type] == :ping
          # PING responses SHOULD be given higher priority than any other frame.
          @frames.unshift(frame)
        else
          @frames << frame
        end
      end

      @frames.shift
    end

    private

    def decode_frame(buf)
      return if buf.size < 9

      frame = read_common_header(buf)

      type = frame[:type]
      length = frame[:length]
      flags = frame[:flags]

      return if buf.size < 9 + length

      raise ProtocolError, "payload too large" if length > @local_max_frame_size

      read_str(buf, 9)
      payload = read_str(buf, length)

      # Implementations MUST discard frames
      # that have unknown or unsupported types.
      # - http://tools.ietf.org/html/draft-ietf-httpbis-http2-16#section-5.5
      return frame unless type

      # Process padding
      padlen = 0
      if FRAME_TYPES_WITH_PADDING.include?(type)
        padded = flags.include?(:padded)
        if padded
          padlen = read_str(payload, 1).unpack1(UINT8)
          frame[:padding] = padlen + 1
          raise ProtocolError, "padding too long" if padlen > payload.bytesize

          payload = payload.byteslice(0, payload.bytesize - padlen) if padlen > 0
          frame[:length] -= frame[:padding]
          flags.delete(:padded)
        end
      end

      case type
      when :data, :ping, :continuation
        frame[:payload] = read_str(payload, length)
      when :headers
        if flags.include?(:priority)
          e_sd = read_uint32(payload)
          frame[:dependency] = e_sd & RBIT
          frame[:exclusive] = e_sd.anybits?(EBIT)
          weight = payload.byteslice(0, 1).ord + 1
          frame[:weight] = weight
          payload = payload.byteslice(1..-1)
        end
        frame[:payload] = read_str(payload, length)
      when :priority
        raise FrameSizeError, "Invalid length for PRIORITY_STREAM (#{length} != 5)" if length != 5

        e_sd = read_uint32(payload)
        frame[:dependency] = e_sd & RBIT
        frame[:exclusive] = e_sd.anybits?(EBIT)
        weight = payload.byteslice(0, 1).ord + 1
        frame[:weight] = weight
        payload = payload.byteslice(1..-1)
      when :rst_stream
        raise FrameSizeError, "Invalid length for RST_STREAM (#{length} != 4)" if length != 4

        frame[:error] = unpack_error read_uint32(payload)

      when :settings
        # NOTE: frame[:length] might not match the number of frame[:payload]
        # because unknown extensions are ignored.
        frame[:payload] = []
        raise ProtocolError, "Invalid settings payload length" unless (length % 6).zero?

        raise ProtocolError, "Invalid stream ID (#{frame[:stream]})" if frame[:stream].nonzero?

        (frame[:length] / 6).times do
          id  = read_str(payload, 2).unpack1(UINT16)
          val = read_uint32(payload)

          # Unsupported or unrecognized settings MUST be ignored.
          # Here we send it along.
          name, = DEFINED_SETTINGS.find { |_name, v| v == id }
          frame[:payload] << [name, val] if name
        end
      when :push_promise
        frame[:promise_stream] = read_uint32(payload) & RBIT
        frame[:payload] = read_str(payload, length)
      when :goaway
        frame[:last_stream] = read_uint32(payload) & RBIT
        frame[:error] = unpack_error read_uint32(payload)

        size = length - 8 # for last_stream and error
        frame[:payload] = read_str(payload, size) if size > 0
      when :window_update
        raise FrameSizeError, "Invalid length for WINDOW_UPDATE (#{length} not multiple of 4)" if length % 4 != 0

        frame[:increment] = read_uint32(payload) & RBIT
      when :altsvc
        frame[:max_age], frame[:port] = read_str(payload, 6).unpack(UINT32 + UINT16)

        len = payload.byteslice(0, 1).ord
        payload = payload.byteslice(1..-1)
        frame[:proto] = read_str(payload, len) if len > 0

        len = payload.byteslice(0, 1).ord
        payload = payload.byteslice(1..-1)
        frame[:host] = read_str(payload, len) if len > 0

        frame[:origin] = read_str(payload, payload.size) unless payload.empty?

      when :origin
        origins = []

        until payload.empty?
          len = read_str(payload, 2).unpack1(UINT16)
          origins << read_str(payload, len)
        end

        frame[:payload] = origins
        # else # Unknown frame type is explicitly allowed
      end

      frame
    end

    def pack_error(error, buffer:)
      unless error.is_a? Integer
        error = DEFINED_ERRORS[error]

        raise CompressionError, "Unknown error ID for #{error}" unless error
      end

      pack([error], UINT32, buffer: buffer)
    end

    def unpack_error(error)
      DEFINED_ERRORS.key(error) || error
    end
  end
end
