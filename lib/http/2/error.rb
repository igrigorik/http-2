module HTTP2
  module Error
    class HeaderException < Exception; end

    class ProtocolError < Exception; end
    class FlowControlError < ProtocolError; end
    class StreamError < ProtocolError; end

    class StreamLimitExceeded < Exception; end
    class ConnectionClosed < Exception; end
    class CompressionError < Exception; end
  end
end
