require "../chunks"
require "./writable"

module Pylon::Wire::Message
  struct TreeUpdate
    include Writable

    getter sequence : UInt32
    getter root : Core::Entry?

    def initialize(@sequence : UInt32, @root : Core::Entry?) : Nil
    end

    def tag : Tag
      Tag::TreeUpdate
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(sequence, FORMAT)
      Chunks.write_entry(io, root)
    end
  end
end
