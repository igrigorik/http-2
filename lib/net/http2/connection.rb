module Net
  module HTTP2

    DEFAULT_FLOW_WINDOW = 65535

    class Connection
      def initialize()
        @next_streamID = 0 # todo

        @streams = {}
      end

      def allocate_stream
        @next_streamID += 2
        @streams[@next_streamID] = Stream.new(self, @next_streamID)
      end
    end
  end
end

# conn = Net::HTTP2::Connection.new
# conn << data

# s = conn.allocate_stream(promise | headers)
# s.headers()
# s.data()
# s.data(finish)

# s.on_headers {}
# s.on_data {}
#
# s.on_open {}
# s.on_close {}


# conn.on_stream do |s|
#   s.
# end

# * stream management
#   - create new streams
#   - process push streams
#   - enforce stream limits
# * setting management (prelude)
# * flow control
# * lifecycle: ping/pong, goaway, protocol errors
