require "helper"

describe HTTP2::Buffer do

  let(:b) { Buffer.new("émalgré") }

  it "should force 8-bit encoding" do
    b.encoding.to_s.should eq "ASCII-8BIT"
  end

  it "should return bytesize of the buffer" do
    b.size.should eq 9
  end

  it "should read single byte at a time" do
    9.times { b.read(1).should_not be_nil }
  end

  it "should unpack an unsigned 32-bit int" do
    Buffer.new([256].pack("N")).read_uint32.should eq 256
  end

end
