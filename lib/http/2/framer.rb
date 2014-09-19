module HTTP2

  # Performs encoding, decoding, and validation of binary HTTP 2.0 frames.
  #
  class Framer
    include Error

    # Maximum frame size (16383 bytes)
    MAX_PAYLOAD_SIZE = 2**14-1

    # Maximum stream ID (2^31)
    MAX_STREAM_ID = 0x7fffffff

    # Maximum window increment value (2^31)
    MAX_WINDOWINC = 0x7fffffff

    # HTTP 2.0 frame type mapping as defined by the spec
    FRAME_TYPES = {
      data:          0x0,
      headers:       0x1,
      priority:      0x2,
      rst_stream:    0x3,
      settings:      0x4,
      push_promise:  0x5,
      ping:          0x6,
      goaway:        0x7,
      window_update: 0x9,
      continuation:  0xa
    }

    # Per frame flags as defined by the spec
    FRAME_FLAGS = {
      data: {
        end_stream:  0, reserved: 1
      },
      headers: {
        end_stream:  0, reserved: 1,
        end_headers: 2, priority: 3
      },
      priority:     {},
      rst_stream:   {},
      settings:     {},
      push_promise: { end_headers: 2 },
      ping:         { pong: 0 },
      goaway:       {},
      window_update:{},
      continuation: {
        end_stream: 0, end_headers: 2
      }
    }

    # Default settings as defined by the spec
    DEFINED_SETTINGS = {
      settings_max_concurrent_streams: 4,
      settings_initial_window_size:    7,
      settings_flow_control_options:   10
    }

    # Default error types as defined by the spec
    DEFINED_ERRORS = {
      no_error:           0,
      protocol_error:     1,
      internal_error:     2,
      flow_control_error: 3,
      stream_closed:      5,
      frame_too_large:    6,
      refused_stream:     7,
      cancel:             8,
      compression_error:  9
    }

    RBIT  = 0x7fffffff
    RBYTE = 0x0fffffff
    HEADERPACK = "CnCCN"
    UINT32 = "N"

    FRAME_LENGTH_HISHIFT = 16
    FRAME_LENGTH_LOMASK  = 0xFFFF

    private_constant :RBIT, :RBYTE, :HEADERPACK, :UINT32

    # Generates common 9-byte frame header.
    # - http://tools.ietf.org/html/draft-ietf-httpbis-http2-14#section-4.1
    #
    # @param frame [Hash]
    # @return [String]
    def commonHeader(frame)
      header = []

      if !FRAME_TYPES[frame[:type]]
        raise CompressionError.new("Invalid frame type (#{frame[:type]})")
      end

      if frame[:length] > MAX_PAYLOAD_SIZE
        raise CompressionError.new("Frame size is too large: #{frame[:length]}")
      end

      if frame[:stream] > MAX_STREAM_ID
        raise CompressionError.new("Stream ID (#{frame[:stream]}) is too large")
      end

      if frame[:type] == :window_update && frame[:increment] > MAX_WINDOWINC
        raise CompressionError.new("Window increment (#{frame[:increment]}) is too large")
      end

      header << (frame[:length] >> FRAME_LENGTH_HISHIFT)
      header << (frame[:length] & FRAME_LENGTH_LOMASK)
      header << FRAME_TYPES[frame[:type]]
      header << frame[:flags].reduce(0) do |acc, f|
        position = FRAME_FLAGS[frame[:type]][f]
        if !position
          raise CompressionError.new("Invalid frame flag (#{f}) for #{frame[:type]}")
        end

        acc |= (1 << position)
        acc
      end

      header << frame[:stream]
      header.pack(HEADERPACK) # 8+16,8,8,32
    end

    # Decodes common 9-byte header.
    #
    # @param buf [Buffer]
    def readCommonHeader(buf)
      frame = {}
      len_hi, len_lo, type, flags, stream = buf.slice(0,9).unpack(HEADERPACK)

      frame[:length] = (len_hi << FRAME_LENGTH_HISHIFT) | len_lo
      frame[:type], _ = FRAME_TYPES.select { |t,pos| type == pos }.first
      frame[:flags] = FRAME_FLAGS[frame[:type]].reduce([]) do |acc, (name, pos)|
        acc << name if (flags & (1 << pos)) > 0
        acc
      end

      frame[:stream] = stream & RBIT
      frame
    end

    # Generates encoded HTTP 2.0 frame.
    # - http://tools.ietf.org/html/draft-ietf-httpbis-http2
    #
    # @param frame [Hash]
    def generate(frame)
      bytes  = Buffer.new
      length = 0

      frame[:flags]  ||= []
      frame[:stream] ||= 0

      case frame[:type]
      when :data
        bytes  << frame[:payload]
        length += frame[:payload].bytesize

      when :headers
        if frame[:priority]
          frame[:flags] += [:priority] if !frame[:flags].include? :priority
        end

        if frame[:flags].include? :priority
          bytes  << [frame[:priority] & RBIT].pack(UINT32)
          length += 4
        end

        bytes  << frame[:payload]
        length += frame[:payload].bytesize

      when :priority
        bytes  << [frame[:priority] & RBIT].pack(UINT32)
        length += 4

      when :rst_stream
        bytes  << pack_error(frame[:error])
        length += 4

      when :settings
        if frame[:stream] != 0
          raise CompressionError.new("Invalid stream ID (#{frame[:stream]})")
        end

        frame[:payload].each do |(k,v)|
          if !k.is_a? Integer
            k = DEFINED_SETTINGS[k]

            if k.nil?
              raise CompressionError.new("Unknown settings ID for #{k}")
            end
          end

          bytes  << [k & RBYTE].pack(UINT32)
          bytes  << [v].pack(UINT32)
          length += 8
        end

      when :push_promise
        bytes  << [frame[:promise_stream] & RBIT].pack(UINT32)
        bytes  << frame[:payload]
        length += 4 + frame[:payload].bytesize

      when :ping
        if frame[:payload].bytesize != 8
          raise CompressionError.new("Invalid payload size \
                                    (#{frame[:payload].size} != 8 bytes)")
        end
        bytes  << frame[:payload]
        length += 8

      when :goaway
        bytes  << [frame[:last_stream] & RBIT].pack(UINT32)
        bytes  << pack_error(frame[:error])
        length += 8

        if frame[:payload]
          bytes  << frame[:payload]
          length += frame[:payload].bytesize
        end

      when :window_update
        bytes  << [frame[:increment] & RBIT].pack(UINT32)
        length += 4

      when :continuation
        bytes  << frame[:payload]
        length += frame[:payload].bytesize
      end

      frame[:length] = length
      bytes.prepend(commonHeader(frame))
    end

    # Decodes complete HTTP 2.0 frame from provided buffer. If the buffer
    # does not contain enough data, no further work is performed.
    #
    # @param buf [Buffer]
    def parse(buf)
      return nil if buf.size < 9
      frame = readCommonHeader(buf)
      return nil if buf.size < 9 + frame[:length]

      buf.read(9)
      payload = buf.read(frame[:length])

      case frame[:type]
      when :data
        frame[:payload] = payload.read(frame[:length])
      when :headers
        if frame[:flags].include? :priority
          frame[:priority] = payload.read_uint32 & RBIT
        end
        frame[:payload] = payload.read(frame[:length])
      when :priority
        frame[:priority] = payload.read_uint32 & RBIT
      when :rst_stream
        frame[:error] = unpack_error payload.read_uint32

      when :settings
        frame[:payload] = {}
        (frame[:length] / 8).times do
          id  = payload.read_uint32 & RBYTE
          val = payload.read_uint32

          # Unsupported or unrecognized settings MUST be ignored.
          name, _ = DEFINED_SETTINGS.select { |name, v| v == id }.first
          frame[:payload][name] = val if name
        end
      when :push_promise
        frame[:promise_stream] = payload.read_uint32 & RBIT
        frame[:payload] = payload.read(frame[:length])
      when :ping
        frame[:payload] = payload.read(frame[:length])
      when :goaway
        frame[:last_stream] = payload.read_uint32 & RBIT
        frame[:error] = unpack_error payload.read_uint32

        size = frame[:length] - 8
        frame[:payload] = payload.read(size) if size > 0
      when :window_update
        frame[:increment] = payload.read_uint32 & RBIT
      when :continuation
        frame[:payload] = payload.read(frame[:length])
      end

      frame
    end

    private

    def pack_error(e)
      if !e.is_a? Integer
        if DEFINED_ERRORS[e].nil?
          raise CompressionError.new("Unknown error ID for #{e}")
        end

        e = DEFINED_ERRORS[e]
      end

      [e].pack(UINT32)
    end

    def unpack_error(e)
      name, _ = DEFINED_ERRORS.select { |name, v| v == e }.first
      name || error
    end

  end
end
