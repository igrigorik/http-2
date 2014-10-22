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

      super
    end

    # Send an outgoing frame. Connection and stream flow control is managed
    # by Connection class.
    #
    # @see Connection
    # @param frame [Hash]
    def send(frame)
      send_connection_preface
      super(frame)
    end

    # Emit the connection preface if not yet
    def send_connection_preface
      if @state == :waiting_connection_preface
        @state = :connected
        emit(:frame, CONNECTION_PREFACE_MAGIC)

        payload = @local_settings.select {|k,v| v != SPEC_DEFAULT_CONNECTION_SETTINGS[k]}
        settings(payload)
      end
    end

  end

end
