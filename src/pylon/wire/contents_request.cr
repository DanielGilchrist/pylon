require "./contents"
require "./binary"
require "./writable"

module Pylon::Wire
  struct ContentsRequest
    include Writable

    getter digests : Array(Bytes)
    getter budget : UInt64

    def initialize(@digests : Array(Bytes), @budget : UInt64)
    end

    def tag : Tag
      Tag::ContentsRequest
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(budget, FORMAT)
      io.write_bytes(digests.size.to_u32, FORMAT)
      digests.each { |digest| Binary.write_bytes(io, digest) }
    end
  end
end
