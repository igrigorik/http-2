require "helper"

describe Http2::Parser::Header do
  let(:c) { Compressor.new }
  let(:d) { Decompressor.new }

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
