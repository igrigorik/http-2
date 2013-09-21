require "helper"

describe HTTP2::Header do

  let(:c) { Compressor.new :request }
  let(:d) { Decompressor.new :response }

  context "literal representation" do
    context "integer" do
      it "should encode 10 using a 5-bit prefix" do
        buf = c.integer(10, 5)
        buf.should eq [10].pack('C')
        d.integer(StringIO.new(buf), 5).should eq 10
      end

      it "should encode 10 using a 0-bit prefix" do
        buf = c.integer(10, 0)
        buf.should eq [10].pack('C')
        d.integer(StringIO.new(buf), 0).should eq 10
      end

      it "should encode 1337 using a 5-bit prefix" do
        buf = c.integer(1337, 5)
        buf.should eq [31,128+26,10].pack('C*')
        d.integer(StringIO.new(buf), 5).should eq 1337
      end

      it "should encode 1337 using a 0-bit prefix" do
        buf = c.integer(1337,0)
        buf.should eq [128+57,10].pack('C*')
        d.integer(StringIO.new(buf), 0).should eq 1337
      end
    end

    context "string" do
      it "should handle ascii codepoints" do
        ascii = "abcdefghij"
        str = c.string(ascii)

        buf = StringIO.new(str+"trailer")
        d.string(buf).should eq ascii
      end

      it "should handle utf-8 codepoints" do
        utf8 = "éáűőúöüó€"
        str = c.string(utf8)

        buf = StringIO.new(str+"trailer")
        d.string(buf).should eq utf8
      end

      it "should handle long utf-8 strings" do
        utf8 = "éáűőúöüó€"*100
        str = c.string(utf8)

        buf = StringIO.new(str+"trailer")
        d.string(buf).should eq utf8
      end
    end
  end

  context "header representation" do
    it "should handle indexed representation" do
      h = {name: 10, type: :indexed}

      indexed = StringIO.new(c.header(h))
      d.header(indexed).should eq h
    end

    context "literal w/o indexing representation" do
      it "should handle indexed header" do
        h = {name: 10, value: "my-value", type: :noindex}

        literal = StringIO.new(c.header(h))
        d.header(literal).should eq h
      end

      it "should handle literal header" do
        h = {name: "x-custom", value: "my-value", type: :noindex}

        literal = StringIO.new(c.header(h))
        d.header(literal).should eq h
      end
    end

    context "literal w/ incremental indexing" do
      it "should handle indexed header" do
        h = {name: 10, value: "my-value", type: :incremental}

        literal = StringIO.new(c.header(h))
        d.header(literal).should eq h
      end

      it "should handle literal header" do
        h = {name: "x-custom", value: "my-value", type: :incremental}

        literal = StringIO.new(c.header(h))
        d.header(literal).should eq h
      end
    end

    context "literal w/ substitution indexing" do
      it "should handle indexed header" do
        h = {name: 1, value: "my-value", index: 10, type: :substitution}

        literal = StringIO.new(c.header(h))
        d.header(literal).should eq h
      end

      it "should handle literal header" do
        h = {name: "x-new", value: "my-value", index: 10, type: :substitution}

        literal = StringIO.new(c.header(h))
        d.header(literal).should eq h
      end
    end
  end

  context "differential coding" do
    context "shared compression context" do
      before(:each) { @cc = CompressionContext.new(:request) }

      it "should be initialized with pre-defined headers" do
        cc = CompressionContext.new(:request)
        cc.table.size.should eq 38

        cc = CompressionContext.new(:response)
        cc.table.size.should eq 35
      end

      it "should be initialized with empty working set" do
        @cc.workset.should be_empty
      end

      it "should update working set based on prior state" do
        @cc.update_sets
        @cc.workset.should be_empty

        # TODO test after adding some data
      end

      context "processing" do
        it "should toggle index representation headers in working set" do
          @cc.process({name: 0, type: :indexed})
          @cc.workset.first.should eq [0, [":scheme", "http"]]

          @cc.process({name: 0, type: :indexed})
          @cc.workset.should be_empty
        end

        context "no indexing" do
          it "should process indexed header with literal value" do
            original_table = @cc.table

            @cc.process({name: 3, value: "/path", type: :noindex})
            @cc.workset.first.should eq [3, [":path", "/path"]]
            @cc.table.should eq original_table
          end

          it "should process indexed header with default value" do
            original_table = @cc.table

            @cc.process({name: 3, type: :noindex})
            @cc.workset.first.should eq [3, [":path", "/"]]
            @cc.table.should eq original_table
          end

          it "should process literal header with literal value" do
            original_table = @cc.table

            @cc.process({name: "x-custom", value: "random", type: :noindex})
            @cc.workset.first.should eq [nil, ["x-custom", "random"]]
            @cc.table.should eq original_table
          end
        end

        context "incremental indexing" do
          it "should process literal header with literal value" do
            original_table = @cc.table.dup

            @cc.process({name: "x-custom", value: "random", type: :incremental})
            @cc.workset.first.should eq [original_table.size, ["x-custom", "random"]]
            (@cc.table - original_table).should eq [["x-custom", "random"]]
          end
        end

        context "substitution indexing" do
          it "should process literal header with literal value" do
            original_table = @cc.table.dup
            idx = original_table.size-1

            @cc.process({
              name: "x-custom", value: "random",
              index: idx, type: :substitution
            })

            @cc.workset.first.should eq [idx, ["x-custom", "random"]]
            (@cc.table - original_table).should eq [["x-custom", "random"]]
            (original_table - @cc.table).should eq [["warning", ""]]
          end

          it "should raise error on invalid substitution index" do
            lambda {
              @cc.process({
                name: "x-custom", value: "random",
                index: 1000, type: :substitution
              })
            }.should raise_error(HeaderException)
          end
        end

        context "size bounds" do
          it "should drop headers from beginning of table" do
            cc = CompressionContext.new(:request, 2048)
            original_table = cc.table.dup
            original_size = original_table.join.bytesize +
                            original_table.size * 32

            cc.process({
              name: "x-custom",
              value: "a" * (2048 - original_size),
              type: :incremental
            })

            cc.table.last[0].should eq "x-custom"
            cc.table.size.should eq original_table.size
           end

          it "should prepend on dropped substitution index" do
            cc = CompressionContext.new(:request, 2048)
            original_table = cc.table.dup
            original_size = original_table.join.bytesize +
                            original_table.size * 32

            cc.process({
              name: "x-custom",
              value: "a" * (2048 - original_size),
              index: 0, type: :substitution
            })

            cc.table[0][0].should eq "x-custom"
            cc.table[1][0].should eq ":scheme"
          end
        end
      end
    end

    context "integration" do
      before (:all) { @cc = CompressionContext.new(:request) }

      it "should match first header set in spec appendix" do
        req_headers = [
          {name: 3, value: "/my-example/index.html"},
          {name: 12, value: "my-user-agent"},
          {name: "x-my-header", value: "first"}
        ]

        req_headers.each {|h| @cc.process(h.merge({type: :incremental})) }

        @cc.table[38].should eq [":path", "/my-example/index.html"]
        @cc.table[39].should eq ["user-agent", "my-user-agent"]
        @cc.table[40].should eq req_headers[2].values
      end

      it "should match second header set in spec appendix" do
        @cc.process({name: 38, type: :indexed})
        @cc.process({name: 39, type: :indexed})
        @cc.process({
          name: 3, value: "/my-example/resources/script.js",
          index: 38, type: :substitution
        })
        @cc.process({name: 40, value: "second", type: :incremental})

        @cc.table[38].should eq [":path", "/my-example/resources/script.js"]
        @cc.table[39].should eq ["user-agent", "my-user-agent"]
        @cc.table[40].should eq ["x-my-header", "first"]
        @cc.table[41].should eq ["x-my-header", "second"]
      end
    end
  end

  context "encode and decode" do
    # http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-01#appendix-B

    before (:all) do
     @cc = Compressor.new(:request)
     @dc = Decompressor.new(:request)
    end

    E1_BYTES = [
      0x44, # (literal header with incremental indexing, name index = 3)
      0x16, # (header value string length = 22)
      "/my-example/index.html".bytes,
      0x4D, # (literal header with incremental indexing, name index = 12)
      0x0D, # (header value string length = 13)
      "my-user-agent".bytes,
      0x40, # (literal header with incremental indexing, new name)
      0x0B, # (header name string length = 11)
      "x-my-header".bytes,
      0x05, # (header value string length = 5)
      "first".bytes
    ].flatten

    E1_HEADERS = [
      [":path", "/my-example/index.html"],
      ["user-agent", "my-user-agent"],
      ["x-my-header", "first"]
    ]

    it "should match first header set in spec appendix" do
      @cc.encode(E1_HEADERS).bytes.should eq E1_BYTES
    end

    it "should decode first header set in spec appendix" do
      @dc.decode(StringIO.new(E1_BYTES.pack("C*"))).should eq E1_HEADERS
    end

    E2_BYTES = [
      0xa6, # (indexed header, index = 38: removal from reference set)
      0xa8, # (indexed header, index = 40: removal from reference set)
      0x04, # (literal header, substitution indexing, name index = 3)
      0x26, # (replaced entry index = 38)
      0x1f, # (header value string length = 31)
      "/my-example/resources/script.js".bytes,
      0x5f,
      0x0a, # (literal header, incremental indexing, name index = 40)
      0x06, # (header value string length = 6)
      "second".bytes
    ].flatten

    E2_HEADERS = [
      [":path", "/my-example/resources/script.js"],
      ["user-agent", "my-user-agent"],
      ["x-my-header", "second"]
    ]

    it "should match second header set in spec appendix" do
      # Force incremental indexing, the spec doesn't specify any strategy
      # for deciding when to use incremental vs substitution indexing, and
      # early implementations defer to incremental by default:
      # - https://github.com/sludin/http2-perl/blob/master/lib/HTTP2/Draft/Compress.pm#L157
      # - https://github.com/MSOpenTech/http2-katana/blob/master/Shared/SharedProtocol/Compression/HeadersDeltaCompression/CompressionProcessor.cs#L259
      # - https://hg.mozilla.org/try/file/9d9a29992e4d/netwerk/protocol/http/Http2CompressionDraft00.cpp#l636
      #
      e2bytes = E2_BYTES.dup
      e2bytes[2] = 0x44     # incremental indexing, name index = 3
      e2bytes.delete_at(3)  # remove replacement index byte

      @cc.encode(E2_HEADERS).bytes.should eq e2bytes
    end

    it "should decode second header set in spec appendix" do
      @dc.decode(StringIO.new(E2_BYTES.pack("C*"))).should match_array E2_HEADERS
    end

    it "encode-decode should be invariant" do
      cc = Compressor.new(:request)
      dc = Decompressor.new(:request)

      E1_HEADERS.should match_array dc.decode(StringIO.new(cc.encode(E1_HEADERS)))
      E2_HEADERS.should match_array dc.decode(StringIO.new(cc.encode(E2_HEADERS)))
    end

    it "should encode-decode request set of headers" do
      cc = Compressor.new(:request)
      dc = Decompressor.new(:request)

      req = [
        [":method", "get"],
        [":host", "localhost"],
        [":path", "/resource"],
        ["accept", "*/*"]
      ]

      dc.decode(StringIO.new(cc.encode(req))).should eq req
    end
  end
end
