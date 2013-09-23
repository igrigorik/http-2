module HTTP2

  # Simple binary buffer backed by string.
  #
  class Buffer < String

    # Forces binary encoding on the string
    def initialize(*args)
      force_encoding('binary')
      super(*args)
    end

    # Emulate StringIO#read: slice first n bytes from the buffer.
    #
    # @param n [Integer] number of bytes to slice from the buffer
    def read(n)
      slice!(0,n)
    end
  end

end
