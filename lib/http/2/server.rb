module HTTP2

  # HTTP 2.0 server connection class that implements appropriate header
  # compression / decompression algorithms and stream management logic.
  #
  # Your code is responsible for feeding request data to the server object,
  # which in turn performs all of the necessary HTTP 2.0 decoding / encoding,
  # state management, and the rest. A simple example:
  #
  # @example
  #     socket = YourTransport.new
  #
  #     conn = HTTP2::Server.new
  #     conn.on(:stream) do |stream|
  #       ...
  #     end
  #
  #     while bytes = socket.read
  #       conn << bytes
  #     end
  #
  class Server < Connection

    # Initialize new HTTP 2.0 server object.
    def initialize(**settings)
      @stream_id    = 2
      @state        = :new

      super
    end

    private

    # Handle locally initiated server-push event emitted by the stream.
    #
    # @param args [Array]
    # @param callback [Proc]
    def promise(*args, &callback)
      parent, headers, flags = *args
      promise = new_stream(parent: parent)
      promise.send({
        type: :push_promise,
        flags: flags,
        stream: parent.id,
        promise_stream: promise.id,
        payload: headers.to_a
      })

      callback.call(promise)
    end
  end

end
