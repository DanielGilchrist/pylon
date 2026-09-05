require "../binary"
require "./writable"

module Pylon::Wire::Message
  struct ReusableResponse
    include Writable

    def initialize(@payload : Array(Bytes)) : Nil
    end

    getter payload : Array(Bytes)

    def tag : Tag
      Tag::ReusableResponse
    end

    def write_payload(io : IO) : Nil
      Binary.write_digests(io, payload)
    end
  end
end
