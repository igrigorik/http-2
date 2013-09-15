module HTTP2
  class Buffer < String
    def initialize(*args)
      force_encoding('binary')
      super(*args)
    end

    def read(n)
      slice!(0,n)
    end
  end
end
