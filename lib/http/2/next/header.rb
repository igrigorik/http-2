# frozen_string_literal: true

module HTTP2Next
  # Implementation of header compression for HTTP 2.0 (HPACK) format adapted
  # to efficiently represent HTTP headers in the context of HTTP 2.0.
  #
  # - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-10
  module Header
    # Header representation as defined by the spec.
    HEADREP = {
      indexed: { prefix: 7, pattern: 0x80 },
      incremental: { prefix: 6, pattern: 0x40 },
      noindex: { prefix: 4, pattern: 0x00 },
      neverindexed: { prefix: 4, pattern: 0x10 },
      changetablesize: { prefix: 5, pattern: 0x20 }
    }.each_value(&:freeze).freeze

    # Predefined options set for Compressor
    # http://mew.org/~kazu/material/2014-hpack.pdf
    NAIVE    = { index: :never,  huffman: :never   }.freeze
    LINEAR   = { index: :all,    huffman: :never   }.freeze
    STATIC   = { index: :static, huffman: :never   }.freeze
    SHORTER  = { index: :all,    huffman: :never   }.freeze
    NAIVEH   = { index: :never,  huffman: :always  }.freeze
    LINEARH  = { index: :all,    huffman: :always  }.freeze
    STATICH  = { index: :static, huffman: :always  }.freeze
    SHORTERH = { index: :all,    huffman: :shorter }.freeze
  end
end

require "http/2/next/header/huffman"
require "http/2/next/header/huffman_statemachine"
require "http/2/next/header/encoding_context"
require "http/2/next/header/compressor"
require "http/2/next/header/decompressor"
