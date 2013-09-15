module Net
  module HTTP2

    MAX_FRAME_SIZE = 2**14-1

    module FlowBuffer
      def buffered_amount
        @send_buffer.map {|f| f[:length] }.reduce(:+) || 0
      end

      private

      def send_data(frame = nil, encode = false)
        @send_buffer.push frame if !frame.nil?

        while @window > 0 && !@send_buffer.empty? do
          frame = @send_buffer.shift

          sent, frame_size = 0, frame[:payload].bytesize

          if frame_size > @window
            payload = frame.delete(:payload)
            chunk   = frame.dup

            frame[:payload] = payload.slice!(0, @window)
            chunk[:length]  = payload.bytesize
            chunk[:payload] = payload

            # if no longer last frame in sequence...
            if frame[:flags].include? :end_stream
              frame[:flags] -= [:end_stream]
            end

            @send_buffer.unshift chunk
            sent = @window
          else
            sent = frame_size
          end

          frame = encode(frame) if encode
          emit(:frame, frame)
          @window -= sent
        end
      end
    end

  end
end
