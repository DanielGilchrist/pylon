require "../binary"
require "./writable"
require "../checksums"

module Pylon::Wire::Message
  struct ChecksumsResponse
    include Writable

    def initialize(@payload : Checksums::Map) : Nil
    end

    getter payload : Checksums::Map

    def tag : Tag
      Tag::ChecksumsResponse
    end

    def write_payload(io : IO) : Nil
      Binary.write_checksums_map(io, payload)
    end
  end
end
