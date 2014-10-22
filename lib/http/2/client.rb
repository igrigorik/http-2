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
      @state        = :connection_header

      super
    end

    # Send an outgoing frame. Connection and stream flow control is managed
    # by Connection class.
    #
    # @see Connection
    # @note Client will emit the connection header as the first 24 bytes
    # @param frame [Hash]
    def send(frame)
      if @state == :connection_header
        emit(:frame, CONNECTION_HEADER)
        @state = :connected

        settings(stream_limit: @stream_limit, window_limit: @window_limit)
      end

      super(frame)
    end
  end

end
