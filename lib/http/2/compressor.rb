require "stringio"

module HTTP2

  # Implementation of header compression for HTTP 2.0 (HPACK) format adapted
  # to efficiently represent HTTP headers in the context of HTTP 2.0.
  #
  # - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression
  module Header

    # The set of components used to encode or decode a header set form an
    # encoding context: an encoding context contains a header table and a
    # reference set - there is one encoding context for each direction.
    #
    class EncodingContext
      include Error

      # TODO: replace StringIO with Buffer...

      # Default request working set as defined by the spec.
      REQ_DEFAULTS = [
        [':scheme'            , 'http' ],
        [':scheme'            , 'https'],
        [':host'              , ''     ],
        [':path'              , '/'    ],
        [':method'            , 'get'  ],
        ['accept'             , ''     ],
        ['accept-charset'     , ''     ],
        ['accept-encoding'    , ''     ],
        ['accept-language'    , ''     ],
        ['cookie'             , ''     ],
        ['if-modified-since'  , ''     ],
        ['user-agent'         , ''     ],
        ['referer'            , ''     ],
        ['authorization'      , ''     ],
        ['allow'              , ''     ],
        ['cache-control'      , ''     ],
        ['connection'         , ''     ],
        ['content-length'     , ''     ],
        ['content-type'       , ''     ],
        ['date'               , ''     ],
        ['expect'             , ''     ],
        ['from'               , ''     ],
        ['if-match'           , ''     ],
        ['if-none-match'      , ''     ],
        ['if-range'           , ''     ],
        ['if-unmodified-since', ''     ],
        ['max-forwards'       , ''     ],
        ['proxy-authorization', ''     ],
        ['range'              , ''     ],
        ['via'                , ''     ]
      ]

      # Default response working set as defined by the spec.
      RESP_DEFAULTS = [
        [':status'                     , '200'],
        ['age'                         , ''   ],
        ['cache-control'               , ''   ],
        ['content-length'              , ''   ],
        ['content-type'                , ''   ],
        ['date'                        , ''   ],
        ['etag'                        , ''   ],
        ['expires'                     , ''   ],
        ['last-modified'               , ''   ],
        ['server'                      , ''   ],
        ['set-cookie'                  , ''   ],
        ['vary'                        , ''   ],
        ['via'                         , ''   ],
        ['access-control-allow-origin' , ''   ],
        ['accept-ranges'               , ''   ],
        ['allow'                       , ''   ],
        ['connection'                  , ''   ],
        ['content-disposition'         , ''   ],
        ['content-encoding'            , ''   ],
        ['content-language'            , ''   ],
        ['content-location'            , ''   ],
        ['content-range'               , ''   ],
        ['link'                        , ''   ],
        ['location'                    , ''   ],
        ['proxy-authenticate'          , ''   ],
        ['refresh'                     , ''   ],
        ['retry-after'                 , ''   ],
        ['strict-transport-security'   , ''   ],
        ['transfer-encoding'           , ''   ],
        ['www-authenticate'            , ''   ]
      ]

      # Current table of header key-value pairs.
      attr_reader :table

      # Current reference set of header key-value pairs.
      attr_reader :refset

      # Initializes compression context with appropriate client/server
      # defaults and maximum size of the header table.
      #
      # @param type [Symbol] either :request or :response
      # @param limit [Integer] maximum header table size in bytes
      def initialize(type, limit = 4096)
        @type = type
        @table = (type == :request) ? REQ_DEFAULTS.dup : RESP_DEFAULTS.dup
        @limit = limit
        @refset = []
      end

      # Performs differential coding based on provided command type.
      # - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-03#section-3.2
      #
      # @param cmd [Hash]
      # @return [Hash] emitted header
      def process(cmd)
        emit = nil

        # indexed representation
        if cmd[:type] == :indexed
          # An indexed representation corresponding to an entry not present
          # in the reference set entails the following actions:
          # - The header corresponding to the entry is emitted.
          # - The entry is added to the reference set.
          #
          # An indexed representation corresponding to an entry present in
          # the reference set entails the following actions:
          #  - The entry is removed from the reference set.
          #
          idx = cmd[:name]
          cur = @refset.find_index {|(i,v)| i == idx}

          if cur
            @refset.delete_at(cur)
          else
            emit = @table[idx]
            @refset.push [idx, @table[idx]]
          end

        else
          # A literal representation that is not added to the header table
          # entails the following action:
          #  - The header is emitted.
          #
          # A literal representation that is added to the header table entails
          # the following actions:
          #  - The header is emitted.
          #  - The header is added to the header table, at the location
          #    defined by the representation.
          #  - The new entry is added to the reference set.
          #
          if cmd[:name].is_a? Integer
            k,v = @table[cmd[:name]]

            cmd[:index] ||= cmd[:name]
            cmd[:value] ||= v
            cmd[:name] = k
          end

          emit = [cmd[:name], cmd[:value]]

          if cmd[:type] != :noindex
            if size_check(cmd)

              case cmd[:type]
              when :incremental
                cmd[:index] = @table.size
              when :substitution
                if @table[cmd[:index]].nil?
                  raise HeaderException.new("invalid index")
                end
              when :prepend
                @table = [emit] + @table
              end

              @table[cmd[:index]] = emit
              @refset.push [cmd[:index], emit]
            end
          end
        end

        emit
      end

      # Emits best available command to encode provided header.
      #
      # @param header [Hash]
      def addcmd(header)
        # check if we have an exact match in header table
        if idx = @table.index(header)
          if !active? idx
            return { name: idx, type: :indexed }
          end
        end

        # check if we have a partial match on header name
        if idx = @table.index {|(k,_)| k == header.first}
          # default to incremental indexing
          cmd = { name: idx, value: header.last, type: :incremental}

          # TODO: implement literal without indexing strategy
          # TODO: implement substitution strategy (if it makes sense)
          # if default? idx
          #   cmd[:type] = :incremental
          # else
          #   cmd[:type] = :substitution
          #   cmd[:index] = idx
          # end

          return cmd
        end

        return { name: header.first, value: header.last, type: :incremental }
      end

      # Emits command to remove current index from working set.
      #
      # @param idx [Integer]
      def removecmd(idx)
        {name: idx, type: :indexed}
      end

      private

      # Before doing such a modification, it has to be ensured that the header
      # table size will stay lower than or equal to the
      # SETTINGS_HEADER_TABLE_SIZE limit. To achieve this, repeatedly, the
      # first entry of the header table is removed, until enough space is
      # available for the modification.
      #
      # A consequence of removing one or more entries at the beginning of the
      # header table is that the remaining entries are renumbered.  The first
      # entry of the header table is always associated to the index 0.
      #
      # @param cmd [Hash]
      # @return [Boolean]
      def size_check(cmd)
        cursize = @table.join.bytesize + @table.size * 32
        cmdsize = cmd[:name].bytesize + cmd[:value].bytesize + 32

        # The addition of a new entry with a size greater than the
        # SETTINGS_HEADER_TABLE_SIZE limit causes all the entries from the
        # header table to be dropped and the new entry not to be added to the
        # header table.  The replacement of an existing entry with a new entry
        # with a size greater than the SETTINGS_HEADER_TABLE_SIZE has the same
        # consequences.
        if cmdsize > @limit
          @table.clear
          return false
        end

        cur = 0
        while (cursize + cmdsize) > @limit do
          e = @table.shift

          # When the modification of the header table is the replacement of an
          # existing entry, the replaced entry is the one indicated in the
          # literal representation before any entry is removed from the header
          # table. If the entry to be replaced is removed from the header table
          # when performing the size adjustment, the replacement entry is
          # inserted at the beginning of the header table.
          if cmd[:type] == :substitution && cur == cmd[:index]
             cmd[:type] = :prepend
           end

          cursize -= (e.join.bytesize + 32)
        end

        return true
      end

      def active?(idx)
        !@refset.find {|i,_| i == idx }.nil?
      end

      def default?(idx)
        t = (@type == :request) ? REQ_DEFAULTS : RESP_DEFAULTS
        idx < t.size
      end
    end

    # Header representation as defined by the spec.
    HEADREP = {
      indexed:      {prefix: 7, pattern: 0x80},
      noindex:      {prefix: 5, pattern: 0x60},
      incremental:  {prefix: 5, pattern: 0x40},
      substitution: {prefix: 6, pattern: 0x00}
    }

    # Responsible for encoding header key-value pairs using HPACK algorithm.
    # Compressor must be initialized with appropriate starting context based
    # on local role: client or server.
    #
    # @example
    #   client_role = Compressor.new(:request)
    #   server_role = Compressor.new(:response)
    class Compressor
      def initialize(type)
        @cc = EncodingContext.new(type)
      end

      # Encodes provided value via integer representation.
      # - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-03#section-4.1.1
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
      # @return [String] binary string
      def integer(i, n)
        limit = 2**n - 1
        return [i].pack('C') if (i < limit)

        bytes = []
        bytes.push limit if !n.zero?

        i -= limit
        while (i >= 128) do
          bytes.push((i % 128) + 128)
          i = i / 128
        end

        bytes.push i
        bytes.pack('C*')
      end

      # Encodes provided value via string literal representation.
      # - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-03#section-4.1.3
      #
      # * The string length, defined as the number of bytes needed to store
      #   its UTF-8 representation, is represented as an integer with a zero
      #   bits prefix. If the string length is strictly less than 128, it is
      #   represented as one byte.
      # * The string value represented as a list of UTF-8 character
      #
      # @param str [String]
      # @return [String] binary string
      def string(str)
        integer(str.bytesize, 0) + str.dup.force_encoding('binary')
      end

      # Encodes header command with appropriate header representation.
      # - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-03#section-4
      #
      # @param h [Hash] header command
      # @param buffer [String]
      def header(h, buffer = "")
        rep = HEADREP[h[:type]]

        if h[:type] == :indexed
          buffer << integer(h[:name], rep[:prefix])

        else
          if h[:name].is_a? Integer
            buffer << integer(h[:name]+1, rep[:prefix])
          else
            buffer << integer(0, rep[:prefix])
            buffer << string(h[:name])
          end

          if h[:type] == :substitution
            buffer << integer(h[:index], 0)
          end

          if h[:value].is_a? Integer
            buffer << integer(h[:value], 0)
          else
            buffer << string(h[:value])
          end
        end

        # set header representation pattern on first byte
        fb = buffer[0].unpack("C").first | rep[:pattern]
        buffer.setbyte(0, fb)

        buffer
      end

      # Encodes provided list of HTTP headers.
      #
      # @param headers [Hash]
      # @return [String] binary string
      def encode(headers)
        commands = []

        # Literal header names MUST be translated to lowercase before
        # encoding and transmission.
        headers.map! {|(hk,hv)| [hk.downcase, hv] }

        # Generate remove commands for missing headers
        @cc.refset.each do |idx, (wk,wv)|
          if headers.find {|(hk,hv)| hk == wk && hv == wv }.nil?
            commands.push @cc.removecmd idx
          end
        end

        # Generate add commands for new headers
        headers.each do |(hk,hv)|
          if @cc.refset.find {|i,(wk,wv)| hk == wk && hv == wv}.nil?
            commands.push @cc.addcmd [hk, hv]
          end
        end

        commands.map do |cmd|
          @cc.process cmd.dup
          header cmd
        end.join
      end
    end

    # Responsible for decoding received headers and maintaining compression
    # context of the opposing peer. Decompressor must be initialized with
    # appropriate starting context based on local role: client or server.
    #
    # @example
    #   server_role = Decompressor.new(:request)
    #   client_role = Decompressor.new(:response)
    class Decompressor
      def initialize(type)
        @cc = EncodingContext.new(type)
      end

      # Decodes integer value from provided buffer.
      #
      # @param buf [String]
      # @param n [Integer] number of available bits
      def integer(buf, n)
        limit = 2**n - 1
        i = !n.zero? ? (buf.getbyte & limit) : 0

        m = 0
        buf.each_byte do |byte|
          i += ((byte & 127) << m)
          m += 7

          break if (byte & 128).zero?
        end if (i == limit)

        i
      end

      # Decodes string value from provided buffer.
      #
      # @param buf [String]
      # @return [String] UTF-8 encoded string
      def string(buf)
        buf.read(integer(buf, 0)).force_encoding('utf-8')
      end

      # Decodes header command from provided buffer.
      #
      # @param buf [String]
      def header(buf)
        peek = buf.getbyte
        buf.seek(-1, IO::SEEK_CUR)

        header = {}
        header[:type], type = HEADREP.select do |t, desc|
          mask = (peek >> desc[:prefix]) << desc[:prefix]
          mask == desc[:pattern]
        end.first

        header[:name] = integer(buf, type[:prefix])
        if header[:type] != :indexed
          header[:name] -= 1

          if header[:name] == -1
            header[:name] = string(buf)
          end

          if header[:type] == :substitution
            header[:index] = integer(buf, 0)
          end

          header[:value] = string(buf)
        end

        header
      end

      # Decodes and processes header commands within provided buffer.
      #
      # Once all the representations contained in a header block have been
      # processed, the headers that are in common with the previous header
      # set are emitted, during the reference set emission.
      #
      # For the reference set emission, each header contained in the
      # reference set that has not been emitted during the processing of the
      # header block is emitted.
      #
      # - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-03#section-3.2.2
      #
      # @param buf [String]
      # @return [Array] set of HTTP headers
      def decode(buf)
        set = []
        set << @cc.process(header(buf)) while !buf.eof?
        @cc.refset.each do |i,header|
          set << header if !set.include? header
        end

        set.compact
      end
    end

  end
end
