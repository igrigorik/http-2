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

      STATIC_ALL = %i[all static].freeze

      STATIC_NEVER = %i[never static].freeze

      # Current table of header key-value pairs.
      attr_reader :table

      # Current encoding settings
      attr_reader :settings

      # Current table size in octets
      attr_reader :current_table_size

      # Initializes compression context with appropriate client/server
      # +settings+ and maximum size of the dynamic table.
      #
      # The dynamic table starts at +settings.table_size+ octets. The same
      # value is the initial maximum size allowed for the table.
      def initialize(settings = Settings.new)
        @table = []
        @table_by_field = Hash.new { |hs, k| hs[k] = [] }
        @unshifts = 0
        @settings = settings
        # Current dynamic table size, as known to both encoder and decoder.
        @limit =
          # Maximum dynamic table size allowed by SETTINGS_HEADER_TABLE_SIZE.
          @max_limit =
            # Smallest maximum size set since the last dynamic table size update.
            @lowest_max_limit = settings.table_size
        @_table_updated = false
        @current_table_size = 0
      end

      # Duplicates current compression context
      def dup
        other = EncodingContext.new(@settings)
        t = @table
        tbf = @table_by_field.transform_values(&:dup)
        unshifts = @unshifts
        l = @limit
        ml = @max_limit
        lml = @lowest_max_limit
        other.instance_eval do
          @table = t.dup # shallow copy
          @table_by_field = tbf
          @unshifts = unshifts
          @limit = l
          @max_limit = ml
          @lowest_max_limit = lml
        end
        other
      end

      # Finds an entry in current dynamic table by +index+.
      # Note that +index+ is zero-based in this module.
      #
      # If the +index+ is greater than the last index in the static table,
      # an entry in the dynamic table is dereferenced.
      #
      # If the +index+ is greater than the last header index, an error is raised.
      def dereference(index)
        # NOTE: index is zero-based in this module.
        return STATIC_TABLE[index] if index < STATIC_TABLE_SIZE

        idx = index - STATIC_TABLE_SIZE

        raise CompressionError, "Index too large" if idx >= @table.size

        @table[index - STATIC_TABLE_SIZE]
      end

      # Header Block Processing
      # - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-10#section-4.1
      def process(cmd)
        type = cmd[:type]

        # The maximum size was reduced below the current table size and the
        # encoder has not signalled a size that fits into it.
        raise CompressionError, "dynamic table size update required" if type != :changetablesize && @lowest_max_limit < @limit

        name = cmd[:name]
        value = cmd[:value]

        case type
        when :changetablesize
          raise CompressionError, "tried to change table size after adding elements to table" if @_table_updated

          # The new maximum size MUST be lower than or equal to the limit set
          # by SETTINGS_HEADER_TABLE_SIZE.
          # - https://www.rfc-editor.org/rfc/rfc7541#section-6.3
          raise CompressionError, "dynamic table size update exceed limit" if value > @max_limit

          # The smallest maximum size set since the last update is signalled.
          @lowest_max_limit = @max_limit if value <= @lowest_max_limit
          self.table_size = value

          nil
        when :indexed
          # Indexed Representation
          # An _indexed representation_ entails the following actions:
          # o  The header field corresponding to the referenced entry in either
          # the static table or dynamic table is added to the decoded header
          # list.
          dereference(name)
        when :incremental, :noindex, :neverindexed
          # A _literal representation_ that is _not added_ to the dynamic table
          # entails the following action:
          # o  The header field is added to the decoded header list.

          # A _literal representation_ that is _added_ to the dynamic table
          # entails the following actions:
          # o  The header field is added to the decoded header list.
          # o  The header field is inserted at the beginning of the dynamic table.

          case name
          when Integer
            name, v = dereference(name)

            value ||= v
          when UPPER
            raise ProtocolError, "Invalid uppercase key: #{name}"
          end

          emit = [name, value]

          # add to table
          cmdsize = name.bytesize + value.bytesize + 32
          if type == :incremental && size_check?(cmdsize)
            @table.unshift(emit)
            @unshifts += 1
            @table_by_field[name].unshift([value, @unshifts])
            @current_table_size += cmdsize
            @_table_updated = true
          end

          emit
        else
          raise CompressionError, "Invalid type: #{type}"
        end
      end

      # Plan +headers+ compression.
      #
      # Emits dynamic table size updates first when the table size has to
      # change. See #max_table_size=.
      def encode(headers)
        # Literals commands are marked with :noindex when index is not used
        noindex = STATIC_NEVER.include?(@settings.index)

        if @lowest_max_limit < @limit
          self.table_size = @lowest_max_limit
          yield({ type: :changetablesize, value: @lowest_max_limit })
        end
        @lowest_max_limit = @max_limit

        max_table_size = @settings.table_size
        max_table_size = @max_limit if @max_limit < max_table_size

        if max_table_size != @limit
          self.table_size = max_table_size
          yield({ type: :changetablesize, value: max_table_size })
        end

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

      # Emits command for a +field+/+value+ header.
      # Prefer static table over dynamic table.
      # Prefer exact match over name-only match.
      #
      def addcmd(field, value)
        # @type var exact: Integer?
        exact = nil
        # @type var name_only: Integer?
        name_only = nil

        index_type = @settings.index

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
          field_entries = @table_by_field[field]

          field_entries&.each do |hvalue, unshift_id|
            abs_index = (@unshifts - unshift_id) + STATIC_TABLE_SIZE
            name_only ||= abs_index
            if value == hvalue
              exact = abs_index
              break
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
        resize_table(0)
      end

      # Set the maximum dynamic table +size+ allowed by
      # SETTINGS_HEADER_TABLE_SIZE.
      #
      # The current table size does not change here. It changes only with a
      # dynamic table size update at the beginning of a header block:
      # - an encoder emits the update in the next #encode call. It uses
      #   +settings.table_size+, capped by this maximum.
      # - a decoder requires the update in the next header block when the
      #   current table size exceeds this maximum.
      #
      # When the maximum is reduced and then increased again before the next
      # header block, the smallest maximum has to be signalled first.
      # - https://www.rfc-editor.org/rfc/rfc7541#section-4.2
      def max_table_size=(size)
        @max_limit = size
        @lowest_max_limit = size if size < @lowest_max_limit
      end

      def listen_on_table
        yield
      ensure
        @_table_updated = false
      end

      private

      def resize_table(cmdsize)
        return if @table.empty?

        while @current_table_size + cmdsize > @limit
          name, value = @table.pop
          @current_table_size -= name.bytesize + value.bytesize + 32

          field_arr = @table_by_field[name]
          field_arr.pop
          @table_by_field.delete(name) if field_arr.empty?

          break if @table.empty?

        end
      end

      # whether +cmd+ fits in the dynamic table.
      #
      # To keep the dynamic table size lower than or equal to @limit,
      # remove one or more entries at the end of the dynamic table.
      def size_check?(cmdsize)
        resize_table(cmdsize)
        cmdsize <= @limit
      end
    end
  end
end
