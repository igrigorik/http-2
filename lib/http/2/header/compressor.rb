# frozen_string_literal: true

module HTTP2
  module Header
    # Responsible for encoding header key-value pairs using HPACK algorithm.
    class Compressor
      include PackingExtensions
      include BufferUtils

      # @param options [Hash] encoding options
      def initialize(options = {})
        @cc = EncodingContext.new(options)
      end

      # Set dynamic table size in EncodingContext
      # @param size [Integer] new dynamic table size
      def table_size=(size)
        @cc.table_size = size
      end

      # Encodes provided value via integer representation.
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
      # @param i [Integer] value to encode
      # @param n [Integer] number of available bits
      # @param buffer [String] buffer to pack bytes into
      # @param offset [Integer] offset to insert packed bytes in buffer
      # @return [String] binary string
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
      # +@options [:huffman]+ controls whether to use Huffman encoding:
      #  :never   Do not use Huffman encoding
      #  :always  Always use Huffman encoding
      #  :shorter Use Huffman when the result is strictly shorter
      #
      # @param str [String]
      # @param buffer [String]
      # @return [String] binary string
      def string(str, buffer = "".b)
        case @cc.options[:huffman]
        when :always
          huffman_string(str, buffer)
        when :never
          plain_string(str, buffer)
        else
          huffman = Huffman.encode(str)
          if huffman.bytesize < str.bytesize
            huffman_offset = buffer.bytesize
            append_str(buffer, huffman)
            set_huffman_size(buffer, huffman_offset)
          else
            plain_string(str, buffer)
          end
        end
      end

      # Encodes header command with appropriate header representation.
      #
      # @param h [Hash] header command
      # @param buffer [String]
      # @return [Buffer]
      def header(h, buffer = "".b)
        rep = HEADREP[h[:type]]
        offset = buffer.size

        case h[:type]
        when :indexed
          integer(h[:name] + 1, rep[:prefix], buffer: buffer)
        when :changetablesize
          integer(h[:value], rep[:prefix], buffer: buffer)
        else
          if h[:name].is_a? Integer
            integer(h[:name] + 1, rep[:prefix], buffer: buffer)
          else
            integer(0, rep[:prefix], buffer: buffer)
            string(h[:name], buffer)
          end

          string(h[:value], buffer)
        end

        # set header representation pattern on first byte
        fb = buffer[offset].ord | rep[:pattern]
        buffer.setbyte(offset, fb)

        buffer
      end

      # Encodes provided list of HTTP headers.
      #
      # @param headers [Array] +[[name, value], ...]+
      # @return [Buffer]
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

      # @param str [String]
      # @param buffer [String]
      # @return [String] binary string
      def huffman_string(str, buffer = "".b)
        huffman_offset = buffer.bytesize
        Huffman.encode(str, buffer)
        set_huffman_size(buffer, huffman_offset)
      end

      # @param str [String]
      # @param buffer [String]
      # @return [String] binary string
      def plain_string(str, plain = "".b)
        integer(str.bytesize, 7, buffer: plain)
        append_str(plain, str)
        plain
      end

      # @param buffer [String]
      # @param huffman_offset [Integer] buffer offset where huffman string was introduced
      # @return [String] binary string
      def set_huffman_size(buffer, huffman_offset)
        integer(buffer.bytesize - huffman_offset, 7, buffer: buffer, offset: huffman_offset)
        buffer.setbyte(huffman_offset, buffer[huffman_offset].ord | 0x80)
        buffer
      end
    end
  end
end
