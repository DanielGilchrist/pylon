require "../binary"
require "./writable"

module Pylon::Wire::Message
  struct ReusableRequest
    include Writable

    def initialize(@digests : Array(Bytes)) : Nil
    end

    getter digests : Array(Bytes)

    def tag : Tag
      Tag::ReusableRequest
    end

    def write_payload(io : IO) : Nil
      Binary.write_digests(io, digests)
    end
  end
end
