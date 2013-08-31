class ProtocolError < Exception; end
class FlowControlError < ProtocolError; end
class StreamError < ProtocolError; end

class StreamLimitExceeded < Exception; end
