module HTTP2

  # Stream, connection, and compressor exceptions.
  module Error

    # Raised if connection header is missing or invalid indicating that
    # this is an invalid HTTP 2.0 request - no frames are emitted and the
    # connection must be aborted.
    class HandshakeError < Exception; end

    # Raised by stream or connection handlers, results in GOAWAY frame
    # which signals termination of the current connection. You *cannot*
    # recover from this exception, or any exceptions subclassed from it.
    class ProtocolError < Exception; end

    # Raised on any header encoding / decoding exception.
    #
    # @see ProtocolError
    class CompressionError < ProtocolError; end

    # Raised on invalid flow control frame or command.
    #
    # @see ProtocolError
    class FlowControlError < ProtocolError; end

    # Raised on invalid stream processing: invalid frame type received or
    # sent, or invalid command issued.
    class StreamError < ProtocolError; end

    #
    # -- Recoverable errors -------------------------------------------------
    #

    # Raised if stream has been closed and new frames cannot be sent.
    class StreamClosed < Exception; end

    # Raised if connection has been closed (or draining) and new stream
    # cannot be opened.
    class ConnectionClosed < Exception; end

    # Raised if stream limit has been reached and new stream cannot be opened.
    class StreamLimitExceeded < Exception; end
  end
end
