# frozen_string_literal: true

require "socket"

puts "Starting server on port 9000"
server = TCPServer.new(9000)

loop do
  sock = server.accept

  puts sock.readpartial(1024).inspect while !sock.closed? && !(begin
    sock.eof?
  rescue StandardError
    true
  end)
end
