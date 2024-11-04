# frozen_string_literal: true

module HTTP2
  module BufferUtils
    def read_str(str, n)
      return "".b if n == 0

      chunk = str.byteslice(0..n - 1)
      remaining = str.byteslice(n..-1)
      remaining ? str.replace(remaining) : str.clear
      chunk
    end

    def read_uint32(str)
      read_str(str, 4).unpack1("N")
    end

    def shift_byte(str)
      read_str(str, 1).ord
    end
  end

  # this mixin handles backwards-compatibility for the new packing options
  # shipping with ruby 3.3 (see https://docs.ruby-lang.org/en/3.3/packed_data_rdoc.html)
  module PackingExtensions
    if RUBY_VERSION < "3.3.0"
      def pack(array_to_pack, template, buffer:, offset: -1)
        packed_str = array_to_pack.pack(template)
        case offset
        when -1
          buffer << packed_str
        when 0
          buffer.prepend(packed_str)
        else
          buffer.insert(offset, packed_str)
        end
      end
    else
      def pack(array_to_pack, template, buffer:, offset: -1)
        case offset
        when -1
          array_to_pack.pack(template, buffer: buffer)
        when 0
          buffer.prepend(array_to_pack.pack(template))
        else
          buffer.insert(offset, array_to_pack.pack(template))
        end
      end
    end
  end
end
