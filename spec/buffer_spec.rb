# frozen_string_literal: true

require 'helper'

RSpec.describe HTTP2::Buffer do
  let(:b) { Buffer.new('émalgré') }

  it 'forces 8-bit encoding' do
    expect(b.encoding.to_s).to eq 'ASCII-8BIT'
  end

  it 'forces 8-bit encoding when adding data' do
    b << 'émalgré'
    expect(b.encoding.to_s).to eq 'ASCII-8BIT'
    b.prepend('émalgré')
    expect(b.encoding.to_s).to eq 'ASCII-8BIT'
  end

  it 'returns bytesize of the buffer' do
    expect(b.size).to eq 9
  end

  it 'reads single byte at a time' do
    9.times { expect(b.read(1)).not_to be_nil }
  end

  it 'unpacks an unsigned 32-bit int' do
    expect(Buffer.new([256].pack('N')).read_uint32).to eq 256
  end
end
