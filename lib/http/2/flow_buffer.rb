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
      @send_buffer.map { |f| f[:length] }.reduce(:+) || 0
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
      @send_buffer.push frame unless frame.nil?

      # FIXME: Frames with zero length with the END_STREAM flag set (that
      # is, an empty DATA frame) MAY be sent if there is no available space
      # in either flow control window.
      while @remote_window > 0 && !@send_buffer.empty?
        frame = @send_buffer.shift

        sent, frame_size = 0, frame[:payload].bytesize

        if frame_size > @remote_window
          payload = frame.delete(:payload)
          chunk   = frame.dup

          # Split frame so that it fits in the window
          # TODO: consider padding!
          frame[:payload] = payload.slice!(0, @remote_window)
          chunk[:length]  = payload.bytesize
          chunk[:payload] = payload

          # if no longer last frame in sequence...
          frame[:flags] -= [:end_stream] if frame[:flags].include? :end_stream

          @send_buffer.unshift chunk
          sent = @remote_window
        else
          sent = frame_size
        end

        manage_state(frame) do
          frames = encode ? encode(frame) : [frame]
          frames.each { |f| emit(:frame, f) }
          @remote_window -= sent
        end
      end
    end

    def process_window_update(frame)
      return if frame[:ignore]
      @remote_window += frame[:increment]
      send_data
    end
  end
end
