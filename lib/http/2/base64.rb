# frozen_string_literal: true

if RUBY_VERSION < "3.3.0"
  require "base64"
elsif !defined?(Base64)
  module HTTP2
    # require "base64" will not be a default gem after ruby 3.4.0
    module Base64
      module_function

      def encode64(bin)
        [bin].pack("m")
      end

      def decode64(str)
        str.unpack1("m")
      end

      def strict_encode64(bin)
        [bin].pack("m0")
      end

      def strict_decode64(str)
        str.unpack1("m0")
      end

      def urlsafe_encode64(bin, padding: true)
        str = strict_encode64(bin)
        str.chomp!("==") or str.chomp!("=") unless padding
        str.tr!("+/", "-_")
        str
      end
    end

    def urlsafe_decode64(str)
      if !str.end_with?("=") && str.length % 4 != 0
        str = str.ljust((str.length + 3) & ~3, "=")
        str.tr!("-_", "+/")
      else
        str = str.tr("-_", "+/")
      end
      strict_decode64(str)
    end
  end
end
