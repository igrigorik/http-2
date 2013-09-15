module Net
  module HTTP2
    module Header
      class HeaderException < Exception; end

      class CompressionContext
        REQ_DEFAULTS = [
          [':scheme'            ,'http' ],
          [':scheme'            ,'https'],
          [':host'              ,''     ],
          [':path'              ,'/'    ],
          [':method'            ,'get'  ],
          ['accept'             ,''     ],
          ['accept-charset'     ,''     ],
          ['accept-encoding'    ,''     ],
          ['accept-language'    ,''     ],
          ['cookie'             ,''     ],
          ['if-modified-since'  ,''     ],
          ['keep-alive'         ,''     ],
          ['user-agent'         ,''     ],
          ['proxy-connection'   ,''     ],
          ['referer'            ,''     ],
          ['accept-datetime'    ,''     ],
          ['authorization'      ,''     ],
          ['allow'              ,''     ],
          ['cache-control'      ,''     ],
          ['connection'         ,''     ],
          ['content-length'     ,''     ],
          ['content-md5'        ,''     ],
          ['content-type'       ,''     ],
          ['date'               ,''     ],
          ['expect'             ,''     ],
          ['from'               ,''     ],
          ['if-match'           ,''     ],
          ['if-none-match'      ,''     ],
          ['if-range'           ,''     ],
          ['if-unmodified-since',''     ],
          ['max-forwards'       ,''     ],
          ['pragma'             ,''     ],
          ['proxy-authorization',''     ],
          ['range'              ,''     ],
          ['te'                 ,''     ],
          ['upgrade'            ,''     ],
          ['via'                ,''     ],
          ['warning'            ,''     ]
        ];

        RESP_DEFAULTS = [
          [':status'                    ,'200'],
          ['age'                        ,''   ],
          ['cache-control'              ,''   ],
          ['content-length'             ,''   ],
          ['content-type'               ,''   ],
          ['date'                       ,''   ],
          ['etag'                       ,''   ],
          ['expires'                    ,''   ],
          ['last-modified'              ,''   ],
          ['server'                     ,''   ],
          ['set-cookie'                 ,''   ],
          ['vary'                       ,''   ],
          ['via'                        ,''   ],
          ['access-control-allow-origin',''   ],
          ['accept-ranges'              ,''   ],
          ['allow'                      ,''   ],
          ['connection'                 ,''   ],
          ['content-disposition'        ,''   ],
          ['content-encoding'           ,''   ],
          ['content-language'           ,''   ],
          ['content-location'           ,''   ],
          ['content-md5'                ,''   ],
          ['content-range'              ,''   ],
          ['link'                       ,''   ],
          ['location'                   ,''   ],
          ['p3p'                        ,''   ],
          ['pragma'                     ,''   ],
          ['proxy-authenticate'         ,''   ],
          ['refresh'                    ,''   ],
          ['retry-after'                ,''   ],
          ['strict-transport-security'  ,''   ],
          ['trailer'                    ,''   ],
          ['transfer-encoding'          ,''   ],
          ['warning'                    ,''   ],
          ['www-authenticate'           ,''   ]
        ];

        attr_reader :table, :workset

        def initialize(type, limit = 4096)
          @type = type
          @table = (type == :request) ? REQ_DEFAULTS.dup : RESP_DEFAULTS.dup
          @limit = limit
          @workset = []
        end

        # differential coding
        # http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-01#section-3.1
        #
        def process(cmd)
          # indexed representation
          if cmd[:type] == :indexed
            # For an indexed representation, the decoder checks whether the index
            # is present in the working set. If true, the corresponding entry is
            # removed from the working set. If several entries correspond to this
            # encoded index, all these entries are removed from the working set.
            # If the index is not present in the working set, it is used to
            # retrieve the corresponding header from the header table, and a new
            # entry is added to the working set representing this header.
            cur = @workset.find_index {|(i,v)| i == cmd[:name]}

            if cur
              @workset.delete_at(cur)
            else
              @workset.push [cmd[:name], @table[cmd[:name]]]
            end

          else
            # For a literal representation, a new entry is added to the working
            # set representing this header. If the literal representation specifies
            # that the header is to be indexed, the header is added accordingly to
            # the header table, and its index is included in the entry in the working
            # set. Otherwise, the entry in the working set contains an undefined index.
            if cmd[:name].is_a? Integer
              k,v = @table[cmd[:name]]

              cmd[:index] ||= cmd[:name]
              cmd[:value] ||= v
              cmd[:name] = k
            end

            newval = [cmd[:name], cmd[:value]]

            if cmd[:type] != :noindex
              size_check cmd

              case cmd[:type]
              when :incremental
                cmd[:index] = @table.size
              when :substitution
                raise HeaderException.new("invalid index") if @table[cmd[:index]].nil?
              when :prepend
                @table = [newval] + @table
              end

              @table[cmd[:index]] = newval
            end

            @workset.push [cmd[:index], newval]
          end
        end

        # Before adding a new entry to the header table or changing an existing
        # one, a check has to be performed to ensure that the change will not
        # cause the table to grow in size beyond the SETTINGS_MAX_BUFFER_SIZE
        # limit. If necessary, one or more items from the beginning of the
        # table are removed until there is enough free space available to make
        # the modification.  Dropping an entry from the beginning of the table
        # causes the index positions of the remaining entries in the table to
        # be decremented by 1.
        def size_check(cmd)
          cursize = @table.join.bytesize + @table.size * 32
          cmdsize = cmd[:name].bytesize + cmd[:value].bytesize + 32

          cur = 0
          while (cursize + cmdsize) > @limit do
            e = @table.shift

            # When using substitution indexing, it is possible that the existing
            # item being replaced might be one of the items removed when performing
            # the necessary size adjustment.  In such cases, the substituted value
            # being added to the header table is inserted at the beginning of the
            # header table (at index position #0) and the index positions of the
            # other remaining entries in the table are incremented by 1.
            if cmd[:type] == :substitution && cur == cmd[:index]
               cmd[:type] = :prepend
             end

            cursize -= (e.join.bytesize + 32)
          end
        end

        # First, upon starting the decoding of a new set of headers, the
        # reference set of headers is interpreted into the working set of
        # headers: for each header in the reference set, an entry is added to
        # the working set, containing the header name, its value, and its
        # current index in the header table.
        def update_sets
          # new refset is the the workset sans headers not in header table
          refset = @workset.reject {|(i,h)| !@table.include? h}

          # new workset is the refset with index of each header in header table
          @workset = refset.collect {|(i,h)| [@table.find_index(h), h]}
        end

        def active?(idx)
          !@workset.find {|i,_| i == idx }.nil?
        end

        def default?(idx)
          t = (@type == :request) ? REQ_DEFAULTS : RESP_DEFAULTS
          idx < t.size
        end

        def addcmd(header)
          # check if we have an exact match in header table
          if idx = @table.index(header)
            if !active? idx
              return { name: idx, value: idx, type: :noindex }
            end
          end

          # check if we have a partial match on header name
          if idx = @table.index {|(k,_)| k == header.first}
            # default to incremental indexing
            cmd = { name: idx, value: header.last, type: :incremental}

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

        def removecmd(idx)
          {name: idx, type: :indexed}
        end
      end

      HEADREP = {
        indexed:      {prefix: 7, pattern: 0x80},
        noindex:      {prefix: 5, pattern: 0x60},
        incremental:  {prefix: 5, pattern: 0x40},
        substitution: {prefix: 6, pattern: 0x00}
      }

      class Compressor
        def initialize(type)
          @cc = CompressionContext.new(type)
        end

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

          bytes.pack('C*')
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
          integer(str.bytesize, 0) + str.force_encoding('binary')
        end

        # Header representation
        # http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-01#section-4.3
        #
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

        def encode(headers)
          commands = []
          @cc.update_sets

          # Remove missing headers from the working set
          @cc.workset.each do |idx, (wk,wv)|
            if headers.find {|(hk,hv)| hk == wk && hv == wv }.nil?
              commands.push @cc.removecmd idx
            end
          end

          # Add missing headers to the working set
          headers.each do |(hk,hv)|
            if @cc.workset.find {|i,(wk,wv)| hk == wk && hv == wv}.nil?
              commands.push @cc.addcmd [hk, hv]
            end
          end

          commands.map do |cmd|
            @cc.process cmd.dup
            header cmd
          end.join
        end
      end

      class Decompressor
        def initialize(type)
          @cc = CompressionContext.new(type)
        end

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

        def string(buf)
          buf.read(integer(buf, 0)).force_encoding('binary')
        end

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

        def decode(buf)
          @cc.update_sets
          @cc.process(header(buf)) while !buf.eof?
          @cc.workset.map {|i,header| header}
        end
      end

    end
  end
end
