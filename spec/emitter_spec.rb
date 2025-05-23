# frozen_string_literal: true

require "helper"

RSpec.describe HTTP2::Emitter do
  class Worker
    include Emitter
    def initialize
      @listeners = Hash.new { |hash, key| hash[key] = [] }
    end
  end

  let(:w) { Worker.new }
  before(:each) do
    @cnt = 0
  end

  it "should raise error on missing callback" do
    expect { w.on(:a) {} }.to_not raise_error
    expect { w.on(:a) }.to raise_error
  end

  it "should allow multiple callbacks on single event" do
    cnt = 0
    w.on(:a) { cnt += 1 }
    w.on(:a) { cnt += 1 }
    w.emit(:a)

    expect(cnt).to eq 2
  end

  it "should execute callback with optional args" do
    args = nil
    w.on(:a) { |a| args = a }
    w.emit(:a, 123)

    expect(args).to eq 123
  end

  it "should pass emitted callbacks to listeners" do
    cnt = 0
    w.on(:a)   { |&block| block.call }
    w.once(:a) { |&block| block.call }
    w.emit(:a) { cnt += 1 }

    expect(cnt).to eq 2
  end

  it "should allow events with no callbacks" do
    expect { w.emit(:missing) }.to_not raise_error
  end

  it "should execute callback exactly once" do
    cnt = 0
    w.on(:a)   { cnt += 1 }
    w.once(:a) { cnt += 1 }
    w.emit(:a)
    w.emit(:a)

    expect(cnt).to eq 3
  end
end
