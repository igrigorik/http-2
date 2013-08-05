module Http2
  module Parser
    module Header

      class CompressionContext
      end

      HEADREP = {
        indexed: {prefix: 7, pattern: 0x80},
        noindex: {prefix: 5, pattern: 0x60},
        incremental: {prefix: 5, pattern: 0x40},
        substitution: {prefix: 6, pattern: 0x00}
      }

      class Compressor

        # Integer representation:
        # http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-01#section-4.2.1
        #
        # If I < 2^N - 1, encode I on N bits
        # Else, encode 2^N - 1 on N bits and do the following steps:
        #  Set I to (I - (2^N - 1)) and Q to 1
        #  While Q > 0
        #    Compute Q and R, quotient and remainder of I divided by 2^7
        #    If Q is strictly greater than 0, write one 1 bit; otherwise, write one 0 bit
        #    Encode R on the next 7 bits
        #    I = Q
        #
        def integer(i, n)
          limit = 2**n - 1
          return [i].pack('C') if (i < limit)

          bytes = []
          bytes.push limit if !n.zero?

          i -= limit
          q = 1

          while (q > 0) do
            q, r = i.divmod(128)
            r += 128 if (q > 0)
            i = q

            bytes.push(r)
          end

          return bytes.pack('C*')
        end

        # String literal representation
        # http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-01#section-4.2.2
        #
        # 1. The string length, defined as the number of bytes needed to store
        # its UTF-8 representation, is represented as an integer with a zero
        # bits prefix. If the string length is strictly less than 128, it is
        # represented as one byte.
        # 2. The string value represented as a list of UTF-8 character
        #
        def string(str)
          [integer(str.bytesize, 0), str.force_encoding('binary')]
        end

        # Header representation
        # http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-01#section-4.3
        #
        #

        def header(h)
          buffers = []

          rep = HEADREP[h[:type]]

          if h[:type] == :indexed
            buffers << integer(h[:name], rep[:prefix])

          else
            if h[:name].is_a? Integer # indexed name
              buffers << integer(h[:name], rep[:prefix])
            else # new name
              buffers << integer(0, rep[:prefix])
              buffers << string(h[:name])
            end

            if h[:type] == :substitution
              buffers << integer(h[:index], 0)
            end

            buffers << string(h[:value])
          end

          # apply pattern on first byte
          fb = buffers.first[0].unpack("C").first | rep[:pattern]
          buffers.first.setbyte(0, fb)

          buffers.join
        end
      end

      class Decompressor

        def integer(buf, n)
          limit = 2**n - 1
          i = !n.zero? ? (buf.getbyte & limit) : 0

          m = 0
          buf.each_byte do |byte|
            i += ((byte & 127) << m)
            m += 7

            break if (byte & 128).zero?
          end if (i == limit)

          return i
        end

        def string(buf)
          buf.read(integer(buf, 0)).force_encoding('binary')
        end

        def header(buf)
          header = {}

          peek = (buf.getbyte >> 5) << 5
          buf.seek(-1, IO::SEEK_CUR)

          if peek == HEADREP[:indexed][:pattern]
            header[:type] = :indexed
            header[:name] = integer(buf, HEADREP[:indexed][:prefix])

          else
            header[:type] = if (peek == HEADREP[:noindex][:pattern])
              :noindex
            elsif (peek == HEADREP[:incremental][:pattern])
              :incremental
            elsif ((peek >> 6) << 6) == HEADREP[:substitution][:pattern]
              :substitution
            end

            header[:name] = integer(buf, HEADREP[header[:type]][:prefix])

            if header[:name].zero?
              header[:name] = string(buf)
            end

            if header[:type] == :substitution
              header[:index] = integer(buf, 0)
            end

            header[:value] = string(buf)
          end

          header
        end
      end

    end
  end
end
