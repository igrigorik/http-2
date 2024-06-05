# frozen_string_literal: true

require 'helper'

RSpec.describe HTTP2::Emitter do
  class Worker
    include Emitter
  end

  before do
    @w = Worker.new
    @cnt = 0
  end

  it 'raises error on missing callback' do
    expect { @w.on(:a) {} }.not_to raise_error
    expect { @w.on(:a) }.to raise_error
  end

  it 'allows multiple callbacks on single event' do
    @w.on(:a) { @cnt += 1 }
    @w.on(:a) { @cnt += 1 }
    @w.emit(:a)

    expect(@cnt).to eq 2
  end

  it 'executes callback with optional args' do
    args = nil
    @w.on(:a) { |a| args = a }
    @w.emit(:a, 123)

    expect(args).to eq 123
  end

  it 'passes emitted callbacks to listeners' do
    @w.on(:a)   { |&block| block.call }
    @w.once(:a) { |&block| block.call }
    @w.emit(:a) { @cnt += 1 }

    expect(@cnt).to eq 2
  end

  it 'allows events with no callbacks' do
    expect { @w.emit(:missing) }.not_to raise_error
  end

  it 'executes callback exactly once' do
    @w.on(:a)   { @cnt += 1 }
    @w.once(:a) { @cnt += 1 }
    @w.emit(:a)
    @w.emit(:a)

    expect(@cnt).to eq 3
  end
end
