require "../binary"
require "./writable"

module Pylon::Wire::Message
  struct AvailabilityRequest
    include Writable

    def initialize(@digests : Array(Bytes)) : Nil
    end

    getter digests : Array(Bytes)

    def tag : Tag
      Tag::AvailabilityRequest
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(digests.size.to_u32, FORMAT)
      digests.each { |digest| Binary.write_bytes(io, digest) }
    end
  end
end
