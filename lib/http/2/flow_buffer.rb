# frozen_string_literal: true

module HTTP2
  # Implementation of stream and connection DATA flow control: frames may
  # be split and / or may be buffered based on current flow control window.
  #
  module FlowBuffer
    include Error

    attr_reader :send_buffer

    MAX_WINDOW_SIZE = (2 << 30) - 1

    # Amount of buffered data. Only DATA payloads are subject to flow stream
    # and connection flow control.
    #
    # @return [Integer]
    def buffered_amount
      @send_buffer.bytesize
    end

    def flush
      send_data
    end

    private

    def update_local_window(frame)
      frame_size = frame[:payload].bytesize
      frame_size += frame.fetch(:padding, 0)
      @local_window -= frame_size
    end

    def calculate_window_update(window_max_size)
      # If DATA frame is received with length > 0 and
      # current received window size + delta length is strictly larger than
      # local window size, it throws a flow control error.
      #
      error(:flow_control_error) if @local_window < 0

      # Send WINDOW_UPDATE if the received window size goes over
      # the local window size / 2.
      #
      # The HTTP/2 spec mandates that every DATA frame received
      # generates a WINDOW_UPDATE to send. In some cases however,
      # (ex: DATA frames with short payloads),
      # the noise generated by flow control frames creates enough
      # congestion for this to be deemed very inefficient.
      #
      # This heuristic was inherited from nghttp, which delays the
      # WINDOW_UPDATE until at least half the window is exhausted.
      # This works because the sender doesn't need those increments
      # until the receiver window is exhausted, after which he'll be
      # waiting for the WINDOW_UPDATE frame.
      return unless @local_window <= (window_max_size / 2)

      window_update(window_max_size - @local_window)
    end

    # Buffers outgoing DATA frames and applies flow control logic to split
    # and emit DATA frames based on current flow control window. If the
    # window is large enough, the data is sent immediately. Otherwise, the
    # data is buffered until the flow control window is updated.
    #
    # Buffered DATA frames are emitted in FIFO order.
    #
    # @param frame [Hash]
    # @param encode [Boolean] set to true by connection
    def send_data(frame = nil, encode = false)
      if frame
        if @send_buffer.empty?
          frame_size = frame[:payload].bytesize
          end_stream = frame[:flags].include?(:end_stream)
          # if buffer is empty, and frame is either end 0 length OR
          # is within available window size, skip buffering and send immediately.
          if @remote_window.positive?
            return send_frame(frame, encode) if frame_size <= @remote_window
          elsif frame_size.zero? && end_stream
            return send_frame(frame, encode)
          end
        end

        @send_buffer << frame
      end

      while (frame = @send_buffer.retrieve(@remote_window))
        send_frame(frame, encode)
      end
    end

    def send_frame(frame, encode)
      sent = frame[:payload].bytesize

      manage_state(frame) do
        if encode
          encode(frame)
        else
          emit(:frame, frame)
        end
        @remote_window -= sent
      end
    end

    def process_window_update(frame:, encode: false)
      return if frame[:ignore]

      if (increment = frame[:increment])
        raise ProtocolError, "increment MUST be higher than zero" if increment.zero?

        @remote_window += increment
        error(:flow_control_error, msg: "window size too large") if @remote_window > MAX_WINDOW_SIZE
      end
      send_data(nil, encode)
    end
  end

  class FrameBuffer
    attr_reader :bytesize

    def initialize
      @buffer = []
      @bytesize = 0
    end

    def <<(frame)
      @buffer << frame
      @bytesize += frame[:payload].bytesize
    end

    def empty?
      @buffer.empty?
    end

    def retrieve(window_size)
      frame = @buffer.first or return

      frame_size = frame[:payload].bytesize
      end_stream = frame[:flags].include?(:end_stream)

      # Frames with zero length with the END_STREAM flag set (that
      # is, an empty DATA frame) MAY be sent if there is no available space
      # in either flow control window.
      return if window_size <= 0 && !(frame_size.zero? && end_stream)

      if frame_size > window_size
        chunk   = frame.dup
        payload = frame[:payload]

        # Split frame so that it fits in the window
        # TODO: consider padding!

        chunk[:payload] = payload.byteslice(0, window_size)
        chunk[:length]  = window_size
        frame[:payload] = payload.byteslice(window_size..-1)
        frame[:length] = frame_size - window_size

        # if no longer last frame in sequence...
        chunk[:flags] -= [:end_stream] if end_stream

        @bytesize -= window_size
        chunk
      else
        @bytesize -= frame_size
        @buffer.shift
      end
    end
  end
end
