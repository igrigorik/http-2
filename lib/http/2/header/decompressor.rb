# frozen_string_literal: true

module HTTP2
  module Header
    # Responsible for decoding received headers and maintaining compression
    # context of the opposing peer. Decompressor must be initialized with
    # appropriate starting context based on local role: client or server.
    #
    # @example
    #   server_role = Decompressor.new(:request)
    #   client_role = Decompressor.new(:response)
    class Decompressor
      include Error
      include BufferUtils

      FORBIDDEN_HEADERS = %w[connection te].freeze

      # @param options [Hash] decoding options.  Only :table_size is effective.
      def initialize(options = {})
        @cc = EncodingContext.new(options)
      end

      # Set dynamic table size in EncodingContext
      # @param size [Integer] new dynamic table size
      def table_size=(size)
        @cc.table_size = size
      end

      # Decodes integer value from provided buffer.
      #
      # @param buf [String]
      # @param n [Integer] number of available bits
      # @return [Integer]
      def integer(buf, n)
        limit = (1 << n) - 1
        i = n.zero? ? 0 : (shift_byte(buf) & limit)

        m = 0
        if i == limit
          offset = 0

          buf.each_byte.with_index do |byte, idx|
            offset = idx
            # while (byte = shift_byte(buf))
            i += ((byte & 127) << m)
            m += 7

            break if byte.nobits?(128)
          end

          read_str(buf, offset + 1)
        end

        i
      end

      # Decodes string value from provided buffer.
      #
      # @param buf [String]
      # @return [String] UTF-8 encoded string
      # @raise [CompressionError] when input is malformed
      def string(buf)
        raise CompressionError, "invalid header block fragment" if buf.empty?

        huffman = buf.getbyte(0).allbits?(0x80)
        len = integer(buf, 7)
        str = read_str(buf, len)
        raise CompressionError, "string too short" unless str.bytesize == len

        str = Huffman.decode(str) if huffman
        str.force_encoding(Encoding::UTF_8)
      end

      # Decodes header command from provided buffer.
      #
      # @param buf [Buffer]
      # @return [Hash] command
      def header(buf)
        peek = buf.getbyte(0)

        header_type, type = HEADREP.find do |_, desc|
          mask = (peek >> desc[:prefix]) << desc[:prefix]
          mask == desc[:pattern]
        end

        raise CompressionError unless header_type && type

        header_name = integer(buf, type[:prefix])

        case header_type
        when :indexed
          raise CompressionError if header_name.zero?

          header_name -= 1

          { type: header_type, name: header_name }
        when :changetablesize
          { type: header_type, name: header_name, value: header_name }
        else
          if header_name.zero?
            header_name = string(buf)
          else
            header_name -= 1
          end
          header_value = string(buf)

          { type: header_type, name: header_name, value: header_value }
        end
      end

      # Decodes and processes header commands within provided buffer.
      #
      # @param buf [Buffer]
      # @param frame [HTTP2::Frame, nil]
      # @return [Array] +[[name, value], ...]
      def decode(buf, frame = nil)
        list = []
        decoding_pseudo_headers = true
        @cc.listen_on_table do
          until buf.empty?
            field, value = @cc.process(header(buf))
            next if field.nil?

            is_pseudo_header = field.start_with?(":")
            if !decoding_pseudo_headers && is_pseudo_header
              raise ProtocolError, "one or more pseudo headers encountered after regular headers"
            end

            decoding_pseudo_headers = is_pseudo_header
            raise ProtocolError, "invalid header received: #{field}" if FORBIDDEN_HEADERS.include?(field)

            if frame
              case field
              when ":status"
                frame[:status] = Integer(value)
              when ":method"
                frame[:method] = value
              when "content-length"
                frame[:content_length] = Integer(value)
              when "trailer"
                (frame[:trailer] ||= []) << value
              end
            end
            list << [field, value]
          end
        end
        list
      end
    end
  end
end
