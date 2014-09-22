require "helper"
require 'json'

describe HTTP2::Header do
  folders = %w[
    go-hpack
    haskell-http2-diff
    haskell-http2-diff-huffman
    haskell-http2-linear
    haskell-http2-linear-huffman
    haskell-http2-naive
    haskell-http2-naive-huffman
    haskell-http2-static
    haskell-http2-static-huffman
    #hyper-hpack
    nghttp2
    nghttp2-16384-4096
    nghttp2-change-table-size
    node-http2-hpack
  ]

  context "Decompressor" do
    folders.each do |folder|
      next if folder =~ /#/
      path = File.expand_path("hpack-test-case/#{folder}", File.dirname(__FILE__))
      Dir.exists?(path) or next
      context "#{folder}" do
        Dir.foreach(path) do |file|
          next if file !~ /\.json/
          it "should decode #{file}" do
            story = JSON.parse(File.read("#{path}/#{file}"))
            cases = story['cases']
            table_size = cases[0]['header_table_size'] || 4096
            context = story['context'] ? story['context'].to_sym : :request
            @dc = Decompressor.new(context, table_size: table_size)
            cases.each do |c|
              wire = [c['wire']].pack("H*").force_encoding('binary')
              @emitted = @dc.decode(HTTP2::Buffer.new(wire))
              headers = c['headers'].flat_map(&:to_a)
              @emitted.should eq headers
            end
          end
        end
      end
    end
  end

  context "Compressor" do
    %w[
      LINEAR
      NAIVE
      SHORTER
      STATIC
    ].each do |mode|
      next if mode =~ /#/
      ['', 'H'].each do |huffman|
        [4096, 512].each do |table_size|
          context "with #{mode}#{huffman} mode and table_size #{table_size}" do
            options = eval("HTTP2::Header::#{mode}#{huffman}")
            path = File.expand_path("hpack-test-case/raw-data", File.dirname(__FILE__))
            Dir.foreach(path) do |file|
              next if file !~ /\.json/
              it "should encode #{file}" do
                story = JSON.parse(File.read("#{path}/#{file}"))
                cases = story['cases']
                context = story['context'] ? story['context'].to_sym : :request
                @cc = Compressor  .new(context, table_size: table_size)
                @dc = Decompressor.new(context, table_size: table_size)
                cases.each do |c|
                  headers = c['headers'].flat_map(&:to_a)
                  wire = @cc.encode(headers)
                  decoded = @dc.decode(HTTP2::Buffer.new(wire))
                  decoded.should eq headers
                end
              end
            end
          end
        end
      end
    end
  end
end

