require "../binary"
require "./writable"

module Pylon::Wire::Message
  struct AvailabilityResponse
    include Writable

    def initialize(@payload : Array(Bytes)) : Nil
    end

    getter payload : Array(Bytes)

    def tag : Tag
      Tag::AvailabilityResponse
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(payload.size.to_u32, FORMAT)
      payload.each { |digest| Binary.write_bytes(io, digest) }
    end
  end
end
