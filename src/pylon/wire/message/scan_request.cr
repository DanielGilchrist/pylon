require "../binary"
require "./writable"

module Pylon::Wire::Message
  struct ScanRequest
    include Writable

    def initialize(@now_ns : Int64) : Nil
    end

    getter now_ns : Int64

    def tag : Tag
      Tag::ScanRequest
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(now_ns, FORMAT)
    end
  end
end
