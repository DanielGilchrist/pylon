require "./tag"

module Pylon::Wire::Message
  module Writable
    abstract def tag : Tag
    abstract def write_payload(io : IO) : Nil

    def write(io : IO) : Nil
      io.write_byte(tag.value)
      write_payload(io)
      io.flush
    end
  end
end
