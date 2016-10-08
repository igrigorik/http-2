$LOAD_PATH << 'lib' << '../lib'

require 'optparse'
require 'socket'
require 'openssl'
require 'http/2'
require 'uri'

DRAFT = 'h2'.freeze

class Logger
  def initialize(id)
    @id = id
  end

  def info(msg)
    puts "[Stream #{@id}]: #{msg}"
  end
end

def send_promises(stream)
  push_streams = []

  # send 10 promises
  10.times do |i|
    sleep 1
    puts 'sending push'

    head = {
      ':status' => '200',
      ':path'   => "/other_resource/#{i}",
      'content-type' => 'text/plain',
    }

    stream.promise(head) do |push|
      push.headers(head)
      push_streams << push
    end
  end
  push_streams
end
