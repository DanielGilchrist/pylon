require "../binary"
require "./writable"
require "../checksums"

module Pylon::Wire::Message
  struct ContentsRequest
    include Writable

    def initialize(@digests : Array(Bytes), @budget : UInt64, @checksums : Checksums::Map) : Nil
    end

    getter digests : Array(Bytes)
    getter budget : UInt64
    getter checksums : Checksums::Map

    def tag : Tag
      Tag::ContentsRequest
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(budget, FORMAT)
      Binary.write_digests(io, digests)
      Binary.write_checksums_map(io, checksums)
    end
  end
end
