require 'helper'

describe Http2::Parser do

  context "integer representation" do
    let(:c) { Compressor.new }
    let(:d) { Decompressor.new }

    it "encoding 10 using a 5-bit prefix" do
      buf = c.integer(10, 5)
      buf.should eq [10].pack('C')
      d.integer(buf, 5).should eq 10
    end

    it "encoding 10 using a 0-bit prefix" do
      buf = c.integer(10, 0)
      buf.should eq [10].pack('C')
      d.integer(buf, 0).should eq 10
    end

    it "encoding 1337 using a 5-bit prefix" do
      buf = c.integer(1337, 5)
      buf.should eq [31,128+26,10].pack('C*')
      d.integer(buf, 5).should eq 1337
    end

    it "encoding 1337 using a 0-bit prefix" do
      buf = c.integer(1337,0)
      buf.should eq [128+57,10].pack('C*')
      d.integer(buf, 0).should eq 1337
    end
  end

end
