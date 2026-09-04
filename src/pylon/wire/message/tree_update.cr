require "../binary"
require "../chunks"
require "./writable"

module Pylon::Wire::Message
  struct TreeUpdate
    include Writable

    def initialize(@sequence : UInt32, @root : Core::Entry?, *, @live : Bool) : Nil
    end

    getter sequence : UInt32
    getter root : Core::Entry?
    getter? live : Bool

    def tag : Tag
      Tag::TreeUpdate
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(sequence, FORMAT)
      Binary.write_bool(io, live?)
      Chunks.write_entry(io, root)
    end
  end
end
