# frozen_string_literal: true

require "helper"

RSpec.describe HTTP2Next::Connection do
  include FrameHelpers
  let(:conn) { Client.new }
  let(:f) { Framer.new }

  context "Headers pre/post processing" do
    let(:conn) do
      client = Client.new
      client << f.generate(settings_frame)
      client
    end

    it "should not concatenate multiple occurences of a header field with the same name" do
      input = [
        ["Content-Type", "text/html"],
        ["Cache-Control", "max-age=60, private"],
        %w[Cache-Control must-revalidate]
      ]
      expected = [
        ["content-type", "text/html"],
        ["cache-control", "max-age=60, private"],
        %w[cache-control must-revalidate]
      ]
      headers = []
      conn.on(:frame) do |bytes|
        headers << f.parse(bytes) if [1, 5, 9].include?(bytes[3].ord)
      end

      stream = conn.new_stream
      stream.headers(input)

      expect(headers.size).to eq 1
      emitted = Decompressor.new.decode(headers.first[:payload])
      expect(emitted).to match_array(expected)
    end

    it "should not split zero-concatenated header field values" do
      input = [*RESPONSE_HEADERS,
               ["cache-control", "max-age=60, private\0must-revalidate"],
               ["content-type", "text/html"],
               ["cookie", "a=b\0c=d; e=f"]]
      expected = [*RESPONSE_HEADERS,
                  ["cache-control", "max-age=60, private\0must-revalidate"],
                  ["content-type", "text/html"],
                  ["cookie", "a=b\0c=d; e=f"]]

      result = nil
      conn.on(:stream) do |stream|
        stream.on(:headers) { |h| result = h }
      end

      srv = Server.new
      srv.on(:frame) { |bytes| conn << bytes }
      stream = srv.new_stream
      stream.headers(input)

      expect(result).to eq expected
    end
  end
end
