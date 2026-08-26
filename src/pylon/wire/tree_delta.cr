require "./binary"
require "./writable"

module Pylon::Wire
  struct TreeDelta
    include Writable

    getter sequence : UInt32
    getter changes : Array(Core::Change)

    def initialize(@sequence : UInt32, @changes : Array(Core::Change))
    end

    def tag : Tag
      Tag::TreeDelta
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(sequence, FORMAT)
      Binary.write_changes(io, changes)
    end
  end
end
