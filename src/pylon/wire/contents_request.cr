require "./contents"
require "./binary"
require "./writable"

module Pylon::Wire
  struct ContentsRequest
    include Writable

    getter digests : Array(Bytes)

    def initialize(@digests : Array(Bytes))
    end

    def tag : Tag
      Tag::ContentsRequest
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(digests.size.to_u32, FORMAT)
      digests.each { |digest| Binary.write_bytes(io, digest) }
    end
  end
end
