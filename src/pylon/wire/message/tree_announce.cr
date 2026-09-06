module Pylon::Wire::Message
  struct TreeAnnounce
    include Writable

    def initialize(@bytes : UInt32) : Nil
    end

    getter bytes : UInt32

    def tag : Tag
      Tag::TreeAnnounce
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(bytes, FORMAT)
    end
  end
end
