module HTTP2

  # Implementation of stream and connection DATA flow control: frames may
  # be split and / or may be buffered based on current flow control window.
  #
  module FlowBuffer

    # Amount of buffered data. Only DATA payloads are subject to flow stream
    # and connection flow control.
    #
    # @return [Integer]
    def buffered_amount
      @send_buffer.map {|f| f[:length] }.reduce(:+) || 0
    end

    private

    # Buffers outgoing DATA frames and applies flow control logic to split
    # and emit DATA frames based on current flow control window. If the
    # window is large enough, the data is sent immediately. Otherwise, the
    # data is buffered until the flow control window is updated.
    #
    # Buffered DATA frames are emitted in FIFO order.
    #
    # @param frame [Hash]
    # @param encode [Boolean] set to true by co
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

        frames = encode ? encode(frame) : [frame]
        frames.each {|f| emit(:frame, f) }
        @window -= sent
      end
    end
  end

end
