class ProtocolError < Exception; end
class FlowControlError < ProtocolError; end
class StreamError < ProtocolError; end
