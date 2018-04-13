module HTTP2
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
  #     conn = HTTP2::Client.new
  #     conn.on(:frame) {|bytes| socket << bytes }
  #
  #     while bytes = socket.read
  #       conn << bytes
  #     end
  #
  class Client < Connection
    # Initialize new HTTP 2.0 client object.
    def initialize(**settings)
      @stream_id    = 1
      @state        = :waiting_connection_preface

      @local_role   = :client
      @remote_role  = :server

      @connection_preface_sent = false

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

    def connection_management(frame)
      send_connection_preface
      super
    end

    # sends the preface and initializes the first stream in half-closed state
    def upgrade
      fail ProtocolError unless @stream_id == 1
      send_connection_preface
      new_stream(state: :half_closed_local)
    end

    def self.settings_header(**settings)
      frame = Framer.new.generate(type: :settings, stream: 0, payload: settings)
      Base64.urlsafe_encode64(frame[9..-1])
    end

    private

    # Emit the connection preface if not yet
    def send_connection_preface
      return if @connection_preface_sent

      @connection_preface_sent = true

      emit(:frame, CONNECTION_PREFACE_MAGIC)

      payload = @local_settings.select { |k, v| v != SPEC_DEFAULT_CONNECTION_SETTINGS[k] }
      settings(payload)
    end
  end
end
