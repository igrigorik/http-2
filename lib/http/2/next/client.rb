# frozen_string_literal: true

module HTTP2Next
  # HTTP 2.0 client connection class that implements appropriate header
  # compression / decompression algorithms and stream management logic.
  #
  # Your code is responsible for driving the client object, which in turn
  # performs all of the necessary HTTP 2.0 encoding / decoding, state
  # management, and the rest. A simple example:
  #
  # @example
  #     socket = YourTransport.new
  #
  #     conn = HTTP2Next::Client.new
  #     conn.on(:frame) {|bytes| socket << bytes }
  #
  #     while bytes = socket.read
  #       conn << bytes
  #     end
  #
  class Client < Connection
    # Initialize new HTTP 2.0 client object.
    def initialize(settings = {})
      @stream_id    = 1
      @state        = :waiting_connection_preface

      @local_role   = :client
      @remote_role  = :server

      super
    end

    # Send an outgoing frame. Connection and stream flow control is managed
    # by Connection class.
    #
    # @see Connection
    # @param frame [Hash]
    def send(frame)
      send_connection_preface
      super
    end

    def receive(frame)
      send_connection_preface
      super
    end

    # sends the preface and initializes the first stream in half-closed state
    def upgrade
      @h2c_upgrade = :start
      raise ProtocolError unless @stream_id == 1

      send_connection_preface
      stream = new_stream(state: :half_closed_local)
      @h2c_upgrade = :finished
      stream
    end

    # Emit the connection preface if not yet
    def send_connection_preface
      return unless @state == :waiting_connection_preface

      @state = :connected
      emit(:frame, CONNECTION_PREFACE_MAGIC)

      payload = @local_settings.reject { |k, v| v == SPEC_DEFAULT_CONNECTION_SETTINGS[k] }
      settings(payload)
    end

    def self.settings_header(settings)
      frame = Framer.new.generate(type: :settings, stream: 0, payload: settings)
      Base64.urlsafe_encode64(frame[9..-1])
    end

    private

    def verify_pseudo_headers(frame)
      _verify_pseudo_headers(frame, RESPONSE_MANDATORY_HEADERS)
    end
  end
end
