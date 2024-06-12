# frozen_string_literal: true

module HTTP2
  # Stream, connection, and compressor exceptions.
  module Error
    @types = {}

    class << self
      attr_reader :types
    end

    class Error < StandardError
      def self.inherited(klass)
        super

        type = klass.name or return

        type = type.split("::").last or return

        type = type.gsub(/([^\^])([A-Z])/, '\1_\2').downcase.to_sym
        HTTP2::Error.types[type] = klass
      end
    end

    # Raised if connection header is missing or invalid indicating that
    # this is an invalid HTTP 2.0 request - no frames are emitted and the
    # connection must be aborted.
    class HandshakeError < Error; end

    # Raised by stream or connection handlers, results in GOAWAY frame
    # which signals termination of the current connection. You *cannot*
    # recover from this exception, or any exceptions subclassed from it.
    class ProtocolError < Error; end

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
    class InternalError < ProtocolError; end

    #
    # -- Recoverable errors -------------------------------------------------
    #

    # Raised if stream has been closed and new frames cannot be sent.
    class StreamClosed < Error; end

    # Raised if connection has been closed (or draining) and new stream
    # cannot be opened.
    class ConnectionClosed < Error; end

    # Raised if stream limit has been reached and new stream cannot be opened.
    class StreamLimitExceeded < Error; end

    class FrameSizeError < Error; end

    @types.freeze
  end
end
