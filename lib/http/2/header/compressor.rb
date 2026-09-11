# frozen_string_literal: true

module HTTP2
  module Header
    # Responsible for encoding header key-value pairs using HPACK algorithm.
    class Compressor
      include PackingExtensions
      include BufferUtils

      def initialize(settings = Settings.new)
        @cc = EncodingContext.new(settings)
      end

      # Set dynamic table +size+ in EncodingContext
      def table_size=(size)
        @cc.table_size = size
      end

      # Encodes +i+ via integer representation into +buffer+ at the offset set by +offset+.
      # - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-10#section-5.1
      #
      #  If I < 2^N - 1, encode I on N bits
      #  Else
      #      encode 2^N - 1 on N bits
      #      I = I - (2^N - 1)
      #      While I >= 128
      #           Encode (I % 128 + 128) on 8 bits
      #           I = I / 128
      #      encode (I) on 8 bits
      #
      def integer(i, n, buffer:, offset: buffer.size)
        limit = (1 << n) - 1
        return pack([i], "C", buffer: buffer, offset: offset) if i < limit

        bytes = []
        bytes.push limit unless n.zero?

        i -= limit
        while i >= 128
          bytes.push((i % 128) + 128)
          i /= 128
        end

        bytes.push i
        pack(bytes, "C*", buffer: buffer, offset: offset)
      end

      # Encodes provided value via string literal representation.
      # - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-10#section-5.2
      #
      # * The string length, defined as the number of bytes needed to store
      #   its UTF-8 representation, is represented as an integer with a seven
      #   bits prefix. If the string length is strictly less than 127, it is
      #   represented as one byte.
      # * If the bit 7 of the first byte is 1, the string value is represented
      #   as a list of Huffman encoded octets
      #   (padded with bit 1's until next octet boundary).
      # * If the bit 7 of the first byte is 0, the string value is
      #   represented as a list of UTF-8 encoded octets.
      #
      def string(str, buffer = "".b)
        case @cc.settings.huffman
        when :always
          huffman_string(str, buffer)
        when :never
          plain_string(str, buffer)
        else
          huffman = Huffman.encode(str)
          if huffman.bytesize < str.bytesize
            huffman_offset = buffer.bytesize
            integer(huffman.bytesize, 7, buffer: buffer)
            buffer.setbyte(huffman_offset, buffer.getbyte(huffman_offset) | 0x80)
            append_str(buffer, huffman)
            buffer
          else
            plain_string(str, buffer)
          end
        end
      end

      # Encodes +h+ header command with appropriate header representation into +buffer+.
      def header(h, buffer = "".b)
        type = h[:type]
        rep = HEADREP[type]
        offset = buffer.size

        case type
        when :indexed
          integer(h[:name] + 1, rep[:prefix], buffer: buffer)
        when :changetablesize
          integer(h[:value], rep[:prefix], buffer: buffer)
        else
          name = h[:name]
          if name.is_a? Integer
            integer(name + 1, rep[:prefix], buffer: buffer)
          else
            integer(0, rep[:prefix], buffer: buffer)
            string(name, buffer)
          end

          string(h[:value], buffer)
        end

        # set header representation pattern on first byte
        fb = buffer.getbyte(offset) | rep[:pattern]
        buffer.setbyte(offset, fb)

        buffer
      end

      # Encodes provided list of HTTP headers.
      def encode(headers)
        buffer = "".b
        headers.partition { |f, _| f.start_with? ":" }.each do |hs|
          @cc.encode(hs) do |cmd|
            header(cmd, buffer)
          end
        end

        buffer
      end

      private

      # encodes +str+ into +buffer+ using Huffman encoding.
      def huffman_string(str, buffer = "".b)
        huffman_offset = buffer.bytesize
        buffer << "\x00".b
        Huffman.encode(str, buffer)
        size = buffer.bytesize - huffman_offset - 1

        if size < 127
          buffer.setbyte(huffman_offset, 0x80 | size)
        else
          buffer.slice!(huffman_offset, 1)
          set_huffman_size(buffer, huffman_offset)
        end
        buffer
      end

      # encodes +str+ into +buffer+.
      def plain_string(str, plain = "".b)
        integer(str.bytesize, 7, buffer: plain)
        append_str(plain, str)
        plain
      end

      # encodes the huffman string size from +buffer+ into the string at the offset indicated by +huffman_offset+
      def set_huffman_size(buffer, huffman_offset)
        integer(buffer.bytesize - huffman_offset, 7, buffer: buffer, offset: huffman_offset)
        buffer.setbyte(huffman_offset, buffer.getbyte(huffman_offset) | 0x80)
        buffer
      end
    end
  end
end
