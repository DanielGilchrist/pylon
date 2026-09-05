require "../binary"
require "./writable"

module Pylon::Wire::Message
  struct ChecksumsRequest
    include Writable

    def initialize(@bases : Bases) : Nil
    end

    getter bases : Bases

    def tag : Tag
      Tag::ChecksumsRequest
    end

    def write_payload(io : IO) : Nil
      Binary.write_bases(io, bases)
    end
  end
end
