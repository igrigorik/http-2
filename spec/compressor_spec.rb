require "helper"

describe Http2::Parser::Header do
  let(:c) { Compressor.new }
  let(:d) { Decompressor.new }

  context "differential coding" do
    context "shared compression context" do
      it "should be initialized with pre-defined headers" do
        cc = CompressionContext.new(:request)
        cc.table.size.should eq 38

        cc = CompressionContext.new(:response)
        cc.table.size.should eq 35
      end

      it "should be initialized with empty reference and working sets" do
        cc = CompressionContext.new(:request)
        cc.refset.should be_empty
        cc.workset.should be_empty
      end

      it "should update working and reference sets based on prior state" do
        cc = CompressionContext.new(:request)
        cc.update_sets
        cc.refset.should be_empty
        cc.workset.should be_empty

        # TODO test after adding some data
      end

      context "processing" do
        it "should toggle index representation headers in working set" do
          cc = CompressionContext.new(:request)
          cc.process({name: 0, type: :indexed})
          cc.workset.first.should eq [0, [":scheme", "http"]]

          cc.process({name: 0, type: :indexed})
          cc.workset.should be_empty
        end

        context "no indexing" do
          it "should process indexed header with literal value" do
            cc = CompressionContext.new(:request)
            original_table = cc.table

            cc.process({name: 3, value: "/path", type: :noindex})
            cc.workset.first.should eq [3, [":path", "/path"]]
            cc.table.should eq original_table
          end

          it "should process indexed header with default value" do
            cc = CompressionContext.new(:request)
            original_table = cc.table

            cc.process({name: 3, type: :noindex})
            cc.workset.first.should eq [3, [":path", "/"]]
            cc.table.should eq original_table
          end

          it "should process literal header with literal value" do
            cc = CompressionContext.new(:request)
            original_table = cc.table

            cc.process({name: "x-custom", value: "random", type: :noindex})
            cc.workset.first.should eq [nil, ["x-custom", "random"]]
            cc.table.should eq original_table
          end
        end

        context "incremental indexing" do
          it "should process literal header with literal value" do
            cc = CompressionContext.new(:request)
            original_table = cc.table.dup

            cc.process({name: "x-custom", value: "random", type: :incremental})
            cc.workset.first.should eq [original_table.size, ["x-custom", "random"]]
            (cc.table - original_table).should eq [["x-custom", "random"]]
          end
        end

        context "substitution indexing" do
          it "should process literal header with literal value" do
            cc = CompressionContext.new(:request)
            original_table = cc.table.dup
            idx = original_table.size-1

            cc.process({
              name: "x-custom", value: "random",
              index: idx, type: :substitution
            })

            cc.workset.first.should eq [idx, ["x-custom", "random"]]
            (cc.table - original_table).should eq [["x-custom", "random"]]
            (original_table - cc.table).should eq [["warning", ""]]
          end
        end

        context "size bounds" do
          it "should drop headers from beginning of table" do
            cc = CompressionContext.new(:request, 1024)
            original_table = cc.table.dup
            original_size = original_table.join.bytesize

            cc.process({
              name: "x-custom",
              value: "a" * (1024-original_size-32),
              type: :incremental
            })

            cc.table.last[0].should eq "x-custom"
            cc.table.size.should eq original_table.size
           end

          it "should prepend on dropped substitution index" do
            cc = CompressionContext.new(:request, 1024)
            original_table = cc.table.dup
            original_size = original_table.join.bytesize

            cc.process({
              name: "x-custom",
              value: "a" * (1024-original_size-32),
              index: 0, type: :substitution
            })

            cc.table[0][0].should eq "x-custom"
            cc.table[1][0].should eq ":scheme"
          end
        end
      end
    end

  end


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

end
