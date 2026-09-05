require "./greeting/incompatible"
require "./greeting/foreign"
require "../wire"
require "../problem"

module Pylon::Wire
  module Greeting
    extend self

    alias Any = Incompatible | Foreign | Problem | Nil

    def write(io : IO) : Problem?
      io.write(IDENTITY.to_slice)
      io.write_bytes(PROTOCOL, FORMAT)
      io.flush
      nil
    rescue error : IO::Error
      Problem.new(error.message || "the greeting could not be written")
    end

    def read(io : IO) : Any
      identity = Bytes.new(IDENTITY.bytesize)
      io.read_fully(identity)
      return Foreign.new unless identity == IDENTITY.to_slice

      version = io.read_bytes(UInt32, FORMAT)
      Incompatible.new(version) unless version == PROTOCOL
    rescue error : IO::Error
      Problem.new(error.message || "the stream ended during the greeting")
    end
  end
end
