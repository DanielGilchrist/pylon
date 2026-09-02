require "../patch"
require "../binary"
require "./writable"
require "../delta"

module Pylon::Wire::Message
  struct ContentsRequest
    include Writable

    getter digests : Array(Bytes)
    getter budget : UInt64
    getter signatures : Delta::Signatures

    def initialize(@digests : Array(Bytes), @budget : UInt64, @signatures : Delta::Signatures = Delta::Signatures.new) : Nil
    end

    def tag : Tag
      Tag::ContentsRequest
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(budget, FORMAT)
      io.write_bytes(digests.size.to_u32, FORMAT)
      digests.each { |digest| Binary.write_bytes(io, digest) }

      io.write_bytes(signatures.size.to_u32, FORMAT)

      signatures.each do |wanted, based|
        Binary.write_bytes(io, wanted)
        Binary.write_bytes(io, based.base)
        Binary.write_signature(io, based.signature)
      end
    end
  end
end
