$: << 'lib' << '../lib'

require 'optparse'
require 'socket'
require 'openssl'
require 'http/2'
require 'uri'

DRAFT = 'HTTP-draft-06/2.0'

class Logger
  def initialize(id)
    @id = id
  end

  def info(msg)
    puts "[Stream #{@id}]: #{msg}"
  end
end
