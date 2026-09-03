require "../binary"
require "../chunks"
require "./writable"

module Pylon::Wire::Message
  struct TreeDelta
    include Writable

    def initialize(@sequence : UInt32, @changes : Core::Changes) : Nil
    end

    getter sequence : UInt32
    getter changes : Core::Changes

    def tag : Tag
      Tag::TreeDelta
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(sequence, FORMAT)
      Chunks.write_changes(io, changes)
    end
  end
end
