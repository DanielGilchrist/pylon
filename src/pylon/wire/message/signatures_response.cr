require "../binary"
require "./writable"
require "../delta"

module Pylon::Wire::Message
  struct SignaturesResponse
    include Writable

    def initialize(@payload : Delta::Signatures) : Nil
    end

    getter payload : Delta::Signatures

    def tag : Tag
      Tag::SignaturesResponse
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(payload.size.to_u32, FORMAT)

      payload.each do |wanted, based|
        Binary.write_bytes(io, wanted)
        Binary.write_bytes(io, based.base)
        Binary.write_signature(io, based.signature)
      end
    end
  end
end
