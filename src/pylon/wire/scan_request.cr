require "./contents"
require "./binary"
require "./writable"

module Pylon::Wire
  struct ScanRequest
    include Writable

    getter now_ns : Int64

    def initialize(@now_ns : Int64)
    end

    def tag : Tag
      Tag::ScanRequest
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(now_ns, FORMAT)
    end
  end
end
