# frozen_string_literal: true

module HTTP2
  MAX_HEADER_LIST_SIZE = (2 << 30) - 1

  # Default values for SETTINGS frame, as defined by the spec.
  SPEC_DEFAULT_CONNECTION_SETTINGS = {
    settings_header_table_size: 4096,
    settings_enable_push: 1, # enabled for servers
    settings_max_concurrent_streams: Framer::MAX_STREAM_ID, # unlimited
    settings_initial_window_size: 65_535,
    settings_max_frame_size: 16_384,
    settings_max_header_list_size: MAX_HEADER_LIST_SIZE # unlimited
  }.freeze

  ENCODING_CONTEXT_SETTINGS = %i[huffman index table_size].freeze

  Settings = Struct.new(
    # connection settings
    :settings_header_table_size,
    :settings_enable_push,
    :settings_max_concurrent_streams,
    :settings_initial_window_size,
    :settings_max_frame_size,
    :settings_max_header_list_size,
    # encoding context settings
    :huffman,
    :index,
    :table_size,
    keyword_init: true
  ) do
    def initialize(
      # connection settings
      settings_header_table_size: 4096,
      settings_enable_push: 1,
      settings_max_concurrent_streams: 100,
      settings_initial_window_size: 65_535,
      settings_max_frame_size: 16_384,
      settings_max_header_list_size: MAX_HEADER_LIST_SIZE,
      # encoding context settings
      huffman: :shorter,
      index: :all,
      table_size: 4096
    )
      super
    end

    def connection_settings
      return enum_for(__method__) unless block_given?

      each_pair do |k, v|
        next if ENCODING_CONTEXT_SETTINGS.include?(k)

        yield k, v
      end
    end
  end
end
