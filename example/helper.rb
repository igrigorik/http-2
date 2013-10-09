$: << 'lib' << '../lib'

require 'optparse'
require 'socket'
require 'openssl'
require 'http/2'
require 'uri'

class Logger
  def initialize(id)
    @id = id
  end

  def info(msg)
    puts "[Stream #{@id}]: #{msg}"
  end
end
