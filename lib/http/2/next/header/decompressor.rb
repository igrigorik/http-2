# frozen_string_literal: true

module HTTP2Next
  module Header
    using StringExtensions
    # Responsible for decoding received headers and maintaining compression
    # context of the opposing peer. Decompressor must be initialized with
    # appropriate starting context based on local role: client or server.
    #
    # @example
    #   server_role = Decompressor.new(:request)
    #   client_role = Decompressor.new(:response)
    class Decompressor
      include Error

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
        limit = (2**n) - 1
        i = n.zero? ? 0 : (buf.shift_byte & limit)

        m = 0
        if i == limit
          while (byte = buf.shift_byte)
            i += ((byte & 127) << m)
            m += 7

            break if (byte & 128).zero?
          end
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

        huffman = (buf.getbyte(0) & 0x80) == 0x80
        len = integer(buf, 7)
        str = buf.read(len)
        raise CompressionError, "string too short" unless str.bytesize == len

        str = Huffman.new.decode(str) if huffman
        str.force_encoding(Encoding::UTF_8)
      end

      # Decodes header command from provided buffer.
      #
      # @param buf [Buffer]
      # @return [Hash] command
      def header(buf)
        peek = buf.getbyte(0)

        header = {}
        header[:type], type = HEADREP.find do |_t, desc|
          mask = (peek >> desc[:prefix]) << desc[:prefix]
          mask == desc[:pattern]
        end

        raise CompressionError unless header[:type]

        header[:name] = integer(buf, type[:prefix])

        case header[:type]
        when :indexed
          raise CompressionError if (header[:name]).zero?

          header[:name] -= 1
        when :changetablesize
          header[:value] = header[:name]
        else
          if (header[:name]).zero?
            header[:name] = string(buf)
          else
            header[:name] -= 1
          end
          header[:value] = string(buf)
        end

        header
      end

      FORBIDDEN_HEADERS = %w[connection te].freeze

      # Decodes and processes header commands within provided buffer.
      #
      # @param buf [Buffer]
      # @param frame [HTTP2Next::Frame, nil]
      # @return [Array] +[[name, value], ...]
      def decode(buf, frame = nil)
        list = []
        decoding_pseudo_headers = true
        @cc.listen_on_table do
          until buf.empty?
            field, value = @cc.process(header(buf))
            next if field.nil?

            is_pseudo_header = field.start_with? ":"
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
