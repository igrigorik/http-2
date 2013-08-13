module Http2
  module Parser
    class FramingException < Exception; end

    class Framer

      MAX_PAYLOAD_SIZE = 2**16-1
      MAX_STREAM_ID = 0x7fffffff
      RBIT          = 0x7fffffff

      FRAME_TYPES = {
        data:          0x0,
        headers:       0x1,
        priority:      0x2,
        rst_stream:    0x3,
        settings:      0x4,
        push_promise:  0x5,
        ping:          0x6,
        goaway:        0x7,
        priority:      0x8,
        window_update: 0x9
      }

      FRAME_FLAGS = {
        data: {
          end_stream:  0, reserved: 1
        },
        headers: {
          end_stream:  0, reserved: 1,
          end_headers: 2, priority: 3
        }
      }

      # Frame header:
      # http://tools.ietf.org/html/draft-ietf-httpbis-http2-04#section-4.1
      #
      HEADERPACK = "SCCL"
      UINT32 = "L"

      def commonHeader(frame)
        header = []

        raise FramingException.new("Frame size is too large: #{frame[:length]}") if frame[:length] > MAX_PAYLOAD_SIZE
        raise FramingException.new("Invalid frame type (#{frame[:type]})") if !FRAME_TYPES[frame[:type]]
        raise FramingException.new("Stream ID (#{frame[:stream]}) is too large") if frame[:stream] > MAX_STREAM_ID

        header << frame[:length]
        header << FRAME_TYPES[frame[:type]]
        header << frame[:flags].reduce(0) do |acc, f|
          position = FRAME_FLAGS[frame[:type]][f]
          raise FramingException.new("Invalid frame flag (#{f}) for #{frame[:type]}") if !position
          acc |= (1 << position)
          acc
        end

        header << (frame[:stream] || 0)
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
        when :data
          bytes += frame[:payload]
        when :headers
          if frame[:flags].include? :priority
            bytes += [frame[:priority] & RBIT].pack(UINT32)
          end

          bytes += frame[:payload]
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
        end
        # frame specific logic

        frame
      end

    end
  end
end
