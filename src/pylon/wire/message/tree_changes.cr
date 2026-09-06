module Pylon::Wire::Message
  struct TreeChanges
    include Writable

    def initialize(@sequence : UInt32, @changes : Core::Changes, *, @live : Bool) : Nil
    end

    getter sequence : UInt32
    getter changes : Core::Changes
    getter? live : Bool

    def tag : Tag
      Tag::TreeChanges
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(sequence, FORMAT)
      Binary.write_bool(io, live?)
      Chunks.write_changes(io, changes)
    end
  end
end
