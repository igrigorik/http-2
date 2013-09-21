$: << 'lib' << '../lib'

require 'socket'
require 'http/2'

class Logger
  def initialize(id)
    @id = id
  end

  def info(msg)
    puts "[Stream #{@id}]: #{msg}"
  end
end
