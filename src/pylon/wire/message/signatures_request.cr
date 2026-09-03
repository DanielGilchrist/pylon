require "../binary"
require "./writable"

module Pylon::Wire::Message
  struct SignaturesRequest
    include Writable

    record Pair, wanted : Bytes, base : Bytes

    def initialize(@pairs : Array(Pair)) : Nil
    end

    getter pairs : Array(Pair)

    def tag : Tag
      Tag::SignaturesRequest
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(pairs.size.to_u32, FORMAT)

      pairs.each do |pair|
        Binary.write_bytes(io, pair.wanted)
        Binary.write_bytes(io, pair.base)
      end
    end
  end
end
