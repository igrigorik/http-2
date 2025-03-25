# frozen_string_literal: true

module HTTP2
  # To decompress header blocks, a decoder only needs to maintain a
  # dynamic table as a decoding context.
  # No other state information is needed.
  module Header
    class EncodingContext
      include Error

      UPPER = /[[:upper:]]/.freeze

      # @private
      # Static table
      # - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-10#appendix-A
      STATIC_TABLE = [
        [":authority",                  ""],
        [":method",                     "GET"],
        [":method",                     "POST"],
        [":path",                       "/"],
        [":path",                       "/index.html"],
        [":scheme",                     "http"],
        [":scheme",                     "https"],
        [":status",                     "200"],
        [":status",                     "204"],
        [":status",                     "206"],
        [":status",                     "304"],
        [":status",                     "400"],
        [":status",                     "404"],
        [":status",                     "500"],
        ["accept-charset",              ""],
        ["accept-encoding",             "gzip, deflate"],
        ["accept-language",             ""],
        ["accept-ranges",               ""],
        ["accept",                      ""],
        ["access-control-allow-origin", ""],
        ["age",                         ""],
        ["allow",                       ""],
        ["authorization",               ""],
        ["cache-control",               ""],
        ["content-disposition",         ""],
        ["content-encoding",            ""],
        ["content-language",            ""],
        ["content-length",              ""],
        ["content-location",            ""],
        ["content-range",               ""],
        ["content-type",                ""],
        ["cookie",                      ""],
        ["date",                        ""],
        ["etag",                        ""],
        ["expect",                      ""],
        ["expires",                     ""],
        ["from",                        ""],
        ["host",                        ""],
        ["if-match",                    ""],
        ["if-modified-since",           ""],
        ["if-none-match",               ""],
        ["if-range",                    ""],
        ["if-unmodified-since",         ""],
        ["last-modified",               ""],
        ["link",                        ""],
        ["location",                    ""],
        ["max-forwards",                ""],
        ["proxy-authenticate",          ""],
        ["proxy-authorization",         ""],
        ["range",                       ""],
        ["referer",                     ""],
        ["refresh",                     ""],
        ["retry-after",                 ""],
        ["server",                      ""],
        ["set-cookie",                  ""],
        ["strict-transport-security",   ""],
        ["transfer-encoding",           ""],
        ["user-agent",                  ""],
        ["vary",                        ""],
        ["via",                         ""],
        ["www-authenticate",            ""]
      ].each(&:freeze).freeze

      STATIC_TABLE_BY_FIELD =
        STATIC_TABLE
        .each_with_object({})
        .with_index { |((field, value), hs), idx| (hs[field] ||= []) << [idx, value].freeze }
        .each_value(&:freeze)
        .freeze

      STATIC_TABLE_SIZE = STATIC_TABLE.size

      DEFAULT_OPTIONS = {
        huffman: :shorter,
        index: :all,
        table_size: 4096
      }.freeze

      STATIC_ALL = %i[all static].freeze

      STATIC_NEVER = %i[never static].freeze

      # Current table of header key-value pairs.
      attr_reader :table

      # Current encoding options
      #
      #   :table_size  Integer  maximum dynamic table size in bytes
      #   :huffman     Symbol   :always, :never, :shorter
      #   :index       Symbol   :all, :static, :never
      attr_reader :options

      # Initializes compression context with appropriate client/server
      # defaults and maximum size of the dynamic table.
      #
      # @param options [Hash] encoding options
      #   :table_size  Integer  maximum dynamic table size in bytes
      #   :huffman     Symbol   :always, :never, :shorter
      #   :index       Symbol   :all, :static, :never
      def initialize(options = {})
        @table = []
        @options = DEFAULT_OPTIONS.merge(options)
        @limit = @options[:table_size]
        @_table_updated = false
      end

      # Duplicates current compression context
      # @return [EncodingContext]
      def dup
        other = EncodingContext.new(@options)
        t = @table
        l = @limit
        other.instance_eval do
          @table = t.dup # shallow copy
          @limit = l
        end
        other
      end

      # Finds an entry in current dynamic table by index.
      # Note that index is zero-based in this module.
      #
      # If the index is greater than the last index in the static table,
      # an entry in the dynamic table is dereferenced.
      #
      # If the index is greater than the last header index, an error is raised.
      #
      # @param index [Integer] zero-based index in the dynamic table.
      # @return [Array] +[key, value]+
      def dereference(index)
        # NOTE: index is zero-based in this module.
        value = STATIC_TABLE[index] || @table[index - STATIC_TABLE_SIZE]
        raise CompressionError, "Index too large" unless value

        value
      end

      # Header Block Processing
      # - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-10#section-4.1
      #
      # @param cmd [Hash] { type:, name:, value:, index: }
      # @return [Array, nil] +[name, value]+ header field that is added to the decoded header list,
      #                                      or nil if +cmd[:type]+ is +:changetablesize+
      def process(cmd)
        emit = nil

        case cmd[:type]
        when :changetablesize
          raise CompressionError, "tried to change table size after adding elements to table" if @_table_updated

          # we can receive multiple table size change commands inside a header frame. However,
          # we should blow up if we receive another frame where the new table size is bigger.
          table_size_updated = @limit != @options[:table_size]

          raise CompressionError, "dynamic table size update exceed limit" if !table_size_updated && cmd[:value] > @limit

          self.table_size = cmd[:value]

        when :indexed
          # Indexed Representation
          # An _indexed representation_ entails the following actions:
          # o  The header field corresponding to the referenced entry in either
          # the static table or dynamic table is added to the decoded header
          # list.
          idx = cmd[:name]

          k, v = dereference(idx)
          emit = [k, v]

        when :incremental, :noindex, :neverindexed
          # A _literal representation_ that is _not added_ to the dynamic table
          # entails the following action:
          # o  The header field is added to the decoded header list.

          # A _literal representation_ that is _added_ to the dynamic table
          # entails the following actions:
          # o  The header field is added to the decoded header list.
          # o  The header field is inserted at the beginning of the dynamic table.

          case cmd[:name]
          when Integer
            k, v = dereference(cmd[:name])

            cmd = cmd.dup
            cmd[:index] ||= cmd[:name]
            cmd[:value] ||= v
            cmd[:name] = k
          when UPPER
            raise ProtocolError, "Invalid uppercase key: #{cmd[:name]}"
          end

          emit = [cmd[:name], cmd[:value]]

          add_to_table(emit) if cmd[:type] == :incremental

        else
          raise CompressionError, "Invalid type: #{cmd[:type]}"
        end

        emit
      end

      # Plan header compression according to +@options [:index]+
      #  :never   Do not use dynamic table or static table reference at all.
      #  :static  Use static table only.
      #  :all     Use all of them.
      #
      # @param headers [Array] +[[name, value], ...]+
      # @return [Array] array of commands
      def encode(headers)
        # Literals commands are marked with :noindex when index is not used
        noindex = STATIC_NEVER.include?(@options[:index])

        headers.each do |field, value|
          # Literal header names MUST be translated to lowercase before
          # encoding and transmission.
          field = field.downcase if UPPER.match?(field)
          value = "/" if field == ":path" && value.empty?
          cmd = addcmd(field, value)
          cmd[:type] = :noindex if noindex && cmd[:type] == :incremental
          process(cmd)
          yield cmd
        end
      end

      # Emits command for a header.
      # Prefer static table over dynamic table.
      # Prefer exact match over name-only match.
      #
      # +@options [:index]+ controls whether to use the dynamic table,
      # static table, or both.
      #  :never   Do not use dynamic table or static table reference at all.
      #  :static  Use static table only.
      #  :all     Use all of them.
      #
      # @param field [String] the header field
      # @param value [String] the header value
      # @return [Hash] command
      def addcmd(field, value)
        # @type var exact: Integer?
        exact = nil
        # @type var name_only: Integer?
        name_only = nil

        index_type = @options[:index]

        if STATIC_ALL.include?(index_type) &&
           STATIC_TABLE_BY_FIELD.key?(field)
          STATIC_TABLE_BY_FIELD[field].each do |i, svalue|
            name_only ||= i
            if value == svalue
              exact = i
              break
            end
          end
        end

        if index_type == :all && !exact
          @table.each_with_index do |(hfield, hvalue), i|
            next unless field == hfield

            if value == hvalue
              exact = i + STATIC_TABLE_SIZE
              break
            else
              name_only ||= i + STATIC_TABLE_SIZE
            end
          end
        end

        if exact
          { name: exact, type: :indexed }
        else
          { name: name_only || field, value: value, type: :incremental }
        end
      end

      # Alter dynamic table size.
      #  When the size is reduced, some headers might be evicted.
      def table_size=(size)
        @limit = size
        size_check(nil)
      end

      # Returns current table size in octets
      # @return [Integer]
      def current_table_size
        @table.sum { |k, v| k.bytesize + v.bytesize } + (@table.size * 32)
      end

      def listen_on_table
        yield
      ensure
        @_table_updated = false
      end

      private

      # Add a name-value pair to the dynamic table.
      # Older entries might have been evicted so that
      # the new entry fits in the dynamic table.
      #
      # @param cmd [Array] +[name, value]+
      def add_to_table(cmd)
        return unless size_check(cmd)

        @table.unshift(cmd)
        @_table_updated = true
      end

      # To keep the dynamic table size lower than or equal to @limit,
      # remove one or more entries at the end of the dynamic table.
      #
      # @param cmd [Hash]
      # @return [Boolean] whether +cmd+ fits in the dynamic table.
      def size_check(cmd)
        cursize = current_table_size
        cmdsize = cmd.nil? ? 0 : cmd[0].bytesize + cmd[1].bytesize + 32

        while cursize + cmdsize > @limit
          break if @table.empty?

          e = @table.pop
          cursize -= e[0].bytesize + e[1].bytesize + 32
        end

        cmdsize <= @limit
      end
    end
  end
end
