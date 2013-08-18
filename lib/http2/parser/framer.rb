module Http2
  module Parser
    class FramingException < Exception; end

    class Framer

      MAX_PAYLOAD_SIZE = 2**16-1
      MAX_STREAM_ID = 0x7fffffff
      MAX_WINDOWINC = 0x7fffffff
      RBIT          = 0x7fffffff
      RBYTE         = 0x0fffffff

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
        push_promise: { end_push_promise: 0 },
        ping:         { pong: 0 },
        goaway:       {},
        window_update:{}
      }

      DEFINED_SETTINGS = {
        settings_max_concurrent_streams: 4,
        settings_initial_window_size:    7,
        settings_flow_control_options:   10
      }

      # Frame header:
      # http://tools.ietf.org/html/draft-ietf-httpbis-http2-04#section-4.1
      #
      HEADERPACK = "SCCL"
      UINT32 = "L"

      def commonHeader(frame)
        header = []
        frame[:flags]  ||= []
        frame[:stream] ||= 0

        raise FramingException.new("Frame size is too large: #{frame[:length]}") if frame[:length] > MAX_PAYLOAD_SIZE
        raise FramingException.new("Invalid frame type (#{frame[:type]})") if !FRAME_TYPES[frame[:type]]
        raise FramingException.new("Stream ID (#{frame[:stream]}) is too large") if frame[:stream] > MAX_STREAM_ID
        # raise FramingException.new("Window increment (#{frame[:increment]}) is too large") if frame[:increment] > MAX_WINDOWINC

        header << frame[:length]
        header << FRAME_TYPES[frame[:type]]
        header << frame[:flags].reduce(0) do |acc, f|
          position = FRAME_FLAGS[frame[:type]][f]
          raise FramingException.new("Invalid frame flag (#{f}) for #{frame[:type]}") if !position
          acc |= (1 << position)
          acc
        end

        header << frame[:stream]
        header.pack(HEADERPACK) # 16,8,8,32
      end

      def readCommonHeader(buf)
        frame = {}

        frame[:length], type, flags, stream = buf.read(8).unpack(HEADERPACK)
        frame[:type], _ = FRAME_TYPES.select { |t,pos| type == pos }.first

        frame[:flags] = FRAME_FLAGS[frame[:type]].reduce([]) do |acc, (name, pos)|
          acc << name if (flags & (1 << pos)) > 0
          acc
        end

        frame[:stream] = stream & RBIT
        frame
      end

      def generate(frame)
        bytes = commonHeader(frame)

        case frame[:type]
        # http://tools.ietf.org/html/draft-ietf-httpbis-http2-05#section-6.1
        when :data
          bytes += frame[:payload]

        # http://tools.ietf.org/html/draft-ietf-httpbis-http2-05#section-6.2
        when :headers
          if frame[:flags].include? :priority
            bytes += [frame[:priority] & RBIT].pack(UINT32)
          end
          bytes += frame[:payload]

        # http://tools.ietf.org/html/draft-ietf-httpbis-http2-05#section-6.3
        when :priority
          bytes += [frame[:priority] & RBIT].pack(UINT32)

        # http://tools.ietf.org/html/draft-ietf-httpbis-http2-05#section-6.4
        when :rst_stream
          bytes += [frame[:error]].pack(UINT32)

        # http://tools.ietf.org/html/draft-ietf-httpbis-http2-05#section-6.5
        when :settings
          if frame[:stream] != 0
            raise FramingException.new("Invalid stream ID (#{frame[:stream]})")
          end

          frame[:payload].each do |(k,v)|
            if !k.is_a? Integer
              k = DEFINED_SETTINGS[k]

              if k.nil?
                raise FramingException.new("Unknown settings ID for #{k}")
              end
            end

            bytes += [k & RBYTE].pack(UINT32)
            bytes += [v].pack(UINT32)
          end

        # http://tools.ietf.org/html/draft-ietf-httpbis-http2-05#section-6.6
        when :push_promise
          bytes += [frame[:promise_stream] & RBIT].pack(UINT32)
          bytes += frame[:payload]

        # http://tools.ietf.org/html/draft-ietf-httpbis-http2-05#section-6.6
        when :ping
          if frame[:payload].bytesize != 8
            raise FramingException.new("Invalid payload size \
                                      (#{frame[:payload].size} != 8 bytes)")
          end
          bytes += frame[:payload]

        when :goaway
          bytes += [frame[:last_stream] & RBIT].pack(UINT32)
          bytes += [frame[:error]].pack(UINT32)
          bytes += frame[:payload] if frame[:payload]

        when :window_update
          bytes += [frame[:increment] & RBIT].pack(UINT32)
        end

        bytes
      end

      def parse(buf)
        frame = readCommonHeader(buf)

        case frame[:type]
        when :data
          frame[:payload] = buf.read(frame[:length])
        when :headers
          if frame[:flags].include? :priority
            frame[:priority] = buf.read(4).unpack(UINT32).first & RBIT
          end
          frame[:payload] = buf.read(frame[:length])
        when :priority
          frame[:priority] = buf.read(4).unpack(UINT32).first & RBIT
        when :rst_stream
          frame[:error] = buf.read(4).unpack(UINT32).first
        when :settings
          frame[:payload] = {}
          (frame[:length] / 8).times do
            id  = buf.read(4).unpack(UINT32).first & RBYTE
            val = buf.read(4).unpack(UINT32).first

            name, _ = DEFINED_SETTINGS.select { |name, v| v == id }.first
            frame[:payload][name || id] = val
          end
        when :push_promise
          frame[:promise_stream] = buf.read(4).unpack(UINT32).first & RBIT
          frame[:payload] = buf.read(frame[:length])
        when :ping
          frame[:payload] = buf.read(frame[:length])
        when :goaway
          frame[:last_stream] = buf.read(4).unpack(UINT32).first & RBIT
          frame[:error] = buf.read(4).unpack(UINT32).first

          size = frame[:length] - 8
          frame[:payload] = buf.read(size) if size > 0
        when :window_update
          frame[:increment] = buf.read(4).unpack(UINT32).first & RBIT
        end

        frame
      end

    end
  end
end
