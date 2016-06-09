module HTTP2
  # Simple binary buffer backed by string.
  #
  # TODO: Refactor, it would be better if Buffer were not a String subclass,
  # but rather wrap a string and only expose the mutating API needed so that
  # the possible surface for things to go wrong stays controllable.
  # - https://github.com/igrigorik/http-2/pull/46
  #
  class Buffer < String
    UINT32 = 'N'.freeze
    private_constant :UINT32

    # Forces binary encoding on the string
    def initialize(*)
      super.force_encoding(Encoding::BINARY)
    end

    # Emulate StringIO#read: slice first n bytes from the buffer.
    #
    # @param n [Integer] number of bytes to slice from the buffer
    def read(n)
      Buffer.new(slice!(0, n))
    end

    # Alias getbyte to readbyte
    alias readbyte getbyte

    # Emulate StringIO#getbyte: slice first byte from buffer.
    def getbyte
      read(1).ord
    end

    # Slice unsigned 32-bit integer from buffer.
    # @return [Integer]
    def read_uint32
      read(4).unpack(UINT32).first
    end

    # Ensures that data that is added is binary encoded as well,
    # otherwise this could lead to the Buffer instance changing its encoding.
    [:<<, :prepend].each do |mutating_method|
      define_method(mutating_method) do |string|
        string = string.dup if string.frozen?
        super(string.force_encoding(Encoding::BINARY))
      end
    end
  end
end
