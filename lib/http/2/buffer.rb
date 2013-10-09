module HTTP2

  # Simple binary buffer backed by string.
  #
  class Buffer < String

    UINT32 = "N"
    BINARY = "binary"
    private_constant :UINT32, :BINARY

    # Forces binary encoding on the string
    def initialize(data = '')
      super(data.force_encoding(BINARY))
    end

    # Emulate StringIO#read: slice first n bytes from the buffer.
    #
    # @param n [Integer] number of bytes to slice from the buffer
    def read(n)
      Buffer.new(slice!(0,n))
    end

    # Alias getbyte to readbyte
    alias :readbyte :getbyte

    # Emulate StringIO#getbyte: slice first byte from buffer.
    def getbyte
      read(1).ord
    end

    # Slice unsigned 32-bit integer from buffer.
    # @return [Integer]
    def read_uint32
      read(4).unpack(UINT32).first
    end
  end

end
