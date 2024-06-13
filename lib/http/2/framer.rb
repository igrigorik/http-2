# frozen_string_literal: true

module HTTP2
  # Performs encoding, decoding, and validation of binary HTTP/2 frames.
  #
  class Framer
    using StringExtensions

    include Error
    include PackingExtensions

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
    end

    # Generates common 9-byte frame header.
    # - http://tools.ietf.org/html/draft-ietf-httpbis-http2-16#section-4.1
    #
    # @param frame [Hash]
    # @param buffer [String] buffer to pack bytes into
    # @return [String]
    def common_header(frame, buffer:)
      raise CompressionError, "Invalid frame type (#{frame[:type]})" unless FRAME_TYPES[frame[:type]]

      raise CompressionError, "Frame size is too large: #{frame[:length]}" if frame[:length] > @remote_max_frame_size

      raise CompressionError, "Frame size is invalid: #{frame[:length]}" if frame[:length] < 0

      raise CompressionError, "Stream ID (#{frame[:stream]}) is too large" if frame[:stream] > MAX_STREAM_ID

      if frame[:type] == :window_update && frame[:increment] > MAX_WINDOWINC
        raise CompressionError, "Window increment (#{frame[:increment]}) is too large"
      end

      pack([
             (frame[:length] >> FRAME_LENGTH_HISHIFT),
             (frame[:length] & FRAME_LENGTH_LOMASK),
             FRAME_TYPES[frame[:type]],
             frame[:flags].reduce(0) do |acc, f|
               position = FRAME_FLAGS[frame[:type]][f]
               raise CompressionError, "Invalid frame flag (#{f}) for #{frame[:type]}" unless position

               acc | (1 << position)
             end,
             frame[:stream]
           ], HEADERPACK, buffer: buffer, offset: 0) # 8+16,8,8,32
    end

    # Decodes common 9-byte header.
    #
    # @param buf [Buffer]
    # @return [Hash] the corresponding frame
    def read_common_header(buf)
      frame = {}
      len_hi, len_lo, type, flags, stream = buf.byteslice(0, 9).unpack(HEADERPACK)

      frame[:length] = (len_hi << FRAME_LENGTH_HISHIFT) | len_lo
      frame[:type], = FRAME_TYPES.find { |_t, pos| type == pos }
      if frame[:type]
        frame[:flags] = FRAME_FLAGS[frame[:type]].each_with_object([]) do |(name, pos), acc|
          acc << name if (flags & (1 << pos)) > 0
        end
      end

      frame[:stream] = stream & RBIT
      frame
    end

    # Generates encoded HTTP/2 frame.
    # - http://tools.ietf.org/html/draft-ietf-httpbis-http2
    #
    # @param frame [Hash]
    def generate(frame)
      bytes  = "".b
      length = 0

      frame[:flags] ||= []
      frame[:stream] ||= 0

      case frame[:type]
      when :data
        bytes << frame[:payload]
        bytes.force_encoding(Encoding::BINARY)
        length += frame[:payload].bytesize

      when :headers
        if frame[:weight] || frame[:dependency] || !frame[:exclusive].nil?
          unless frame[:weight] && frame[:dependency] && !frame[:exclusive].nil?
            raise CompressionError, "Must specify all of priority parameters for #{frame[:type]}"
          end

          frame[:flags] += [:priority] unless frame[:flags].include? :priority
        end

        if frame[:flags].include? :priority
          pack([(frame[:exclusive] ? EBIT : 0) | (frame[:dependency] & RBIT)], UINT32, buffer: bytes)
          pack([frame[:weight] - 1], UINT8, buffer: bytes)
          length += 5
        end

        bytes << frame[:payload]
        length += frame[:payload].bytesize

      when :priority
        unless frame[:weight] && frame[:dependency] && !frame[:exclusive].nil?
          raise CompressionError, "Must specify all of priority parameters for #{frame[:type]}"
        end

        pack([(frame[:exclusive] ? EBIT : 0) | (frame[:dependency] & RBIT)], UINT32, buffer: bytes)
        pack([frame[:weight] - 1], UINT8, buffer: bytes)
        length += 5

      when :rst_stream
        pack_error(frame[:error], buffer: bytes)
        length += 4

      when :settings
        raise CompressionError, "Invalid stream ID (#{frame[:stream]})" if (frame[:stream]).nonzero?

        frame[:payload].each do |(k, v)|
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
        pack([frame[:promise_stream] & RBIT], UINT32, buffer: bytes)
        bytes << frame[:payload]
        length += 4 + frame[:payload].bytesize

      when :ping
        raise CompressionError, "Invalid payload size (#{frame[:payload].size} != 8 bytes)" if frame[:payload].bytesize != 8

        bytes << frame[:payload]
        length += 8

      when :goaway
        pack([frame[:last_stream] & RBIT], UINT32, buffer: bytes)
        pack_error(frame[:error], buffer: bytes)
        length += 8

        if frame[:payload]
          bytes << frame[:payload]
          length += frame[:payload].bytesize
        end

      when :window_update
        pack([frame[:increment] & RBIT], UINT32, buffer: bytes)
        length += 4

      when :continuation
        bytes << frame[:payload]
        length += frame[:payload].bytesize

      when :altsvc
        pack([frame[:max_age], frame[:port]], UINT32 + UINT16, buffer: bytes)
        length += 6
        if frame[:proto]
          raise CompressionError, "Proto too long" if frame[:proto].bytesize > 255

          pack([frame[:proto].bytesize], UINT8, buffer: bytes)
          bytes << frame[:proto]
          length += 1 + frame[:proto].bytesize
        else
          pack([0], UINT8, buffer: bytes)
          length += 1
        end
        if frame[:host]
          raise CompressionError, "Host too long" if frame[:host].bytesize > 255

          pack([frame[:host].bytesize], UINT8, buffer: bytes)
          bytes << frame[:host]
          length += 1 + frame[:host].bytesize
        else
          pack([0], UINT8, buffer: bytes)
          length += 1
        end
        if frame[:origin]
          bytes << frame[:origin]
          length += frame[:origin].bytesize
        end

      when :origin
        frame[:payload].each do |origin|
          pack([origin.bytesize], UINT16, buffer: bytes)
          bytes << origin
          length += 2 + origin.bytesize
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

        length += padlen
        pack([padlen -= 1], UINT8, buffer: bytes, offset: 0)
        frame[:flags] << :padded

        # Padding:  Padding octets that contain no application semantic value.
        # Padding octets MUST be set to zero when sending and ignored when
        # receiving.
        bytes << ("\0" * padlen)
      end

      frame[:length] = length
      common_header(frame, buffer: bytes)
    end

    # Decodes complete HTTP/2 frame from provided buffer. If the buffer
    # does not contain enough data, no further work is performed.
    #
    # @param buf [Buffer]
    def parse(buf)
      return if buf.size < 9

      frame = read_common_header(buf)
      return if buf.size < 9 + frame[:length]

      raise ProtocolError, "payload too large" if frame[:length] > @local_max_frame_size

      buf.read(9)
      payload = buf.read(frame[:length])

      # Implementations MUST discard frames
      # that have unknown or unsupported types.
      # - http://tools.ietf.org/html/draft-ietf-httpbis-http2-16#section-5.5
      return frame if frame[:type].nil?

      # Process padding
      padlen = 0
      if FRAME_TYPES_WITH_PADDING.include?(frame[:type])
        padded = frame[:flags].include?(:padded)
        if padded
          padlen = payload.read(1).unpack1(UINT8)
          frame[:padding] = padlen + 1
          raise ProtocolError, "padding too long" if padlen > payload.bytesize

          payload = payload.byteslice(0, payload.bytesize - padlen) if padlen > 0
          frame[:length] -= frame[:padding]
          frame[:flags].delete(:padded)
        end
      end

      case frame[:type]
      when :data, :ping, :continuation
        frame[:payload] = payload.read(frame[:length])
      when :headers
        if frame[:flags].include? :priority
          e_sd = payload.read_uint32
          frame[:dependency] = e_sd & RBIT
          frame[:exclusive] = (e_sd & EBIT) != 0
          weight = payload.byteslice(0, 1).ord + 1
          frame[:weight] = weight
          payload = payload.byteslice(1..-1)
        end
        frame[:payload] = payload.read(frame[:length])
      when :priority
        raise FrameSizeError, "Invalid length for PRIORITY_STREAM (#{frame[:length]} != 5)" if frame[:length] != 5

        e_sd = payload.read_uint32
        frame[:dependency] = e_sd & RBIT
        frame[:exclusive] = (e_sd & EBIT) != 0
        weight = payload.byteslice(0, 1).ord + 1
        frame[:weight] = weight
        payload = payload.byteslice(1..-1)
      when :rst_stream
        raise FrameSizeError, "Invalid length for RST_STREAM (#{frame[:length]} != 4)" if frame[:length] != 4

        frame[:error] = unpack_error payload.read_uint32

      when :settings
        # NOTE: frame[:length] might not match the number of frame[:payload]
        # because unknown extensions are ignored.
        frame[:payload] = []
        raise ProtocolError, "Invalid settings payload length" unless (frame[:length] % 6).zero?

        raise ProtocolError, "Invalid stream ID (#{frame[:stream]})" if (frame[:stream]).nonzero?

        (frame[:length] / 6).times do
          id  = payload.read(2).unpack1(UINT16)
          val = payload.read_uint32

          # Unsupported or unrecognized settings MUST be ignored.
          # Here we send it along.
          name, = DEFINED_SETTINGS.find { |_name, v| v == id }
          frame[:payload] << [name, val] if name
        end
      when :push_promise
        frame[:promise_stream] = payload.read_uint32 & RBIT
        frame[:payload] = payload.read(frame[:length])
      when :goaway
        frame[:last_stream] = payload.read_uint32 & RBIT
        frame[:error] = unpack_error payload.read_uint32

        size = frame[:length] - 8 # for last_stream and error
        frame[:payload] = payload.read(size) if size > 0
      when :window_update
        if frame[:length] % 4 != 0
          raise FrameSizeError, "Invalid length for WINDOW_UPDATE (#{frame[:length]} not multiple of 4)"
        end

        frame[:increment] = payload.read_uint32 & RBIT
      when :altsvc
        frame[:max_age], frame[:port] = payload.read(6).unpack(UINT32 + UINT16)

        len = payload.byteslice(0, 1).ord
        payload = payload.byteslice(1..-1)
        frame[:proto] = payload.read(len) if len > 0

        len = payload.byteslice(0, 1).ord
        payload = payload.byteslice(1..-1)
        frame[:host] = payload.read(len) if len > 0

        frame[:origin] = payload.read(payload.size) unless payload.empty?

      when :origin
        origins = []

        until payload.empty?
          len = payload.read(2).unpack1(UINT16)
          origins << payload.read(len)
        end

        frame[:payload] = origins
        # else # Unknown frame type is explicitly allowed
      end

      frame
    end

    private

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
