require "../binary"
require "./writable"

module Pylon::Wire::Message
  struct ScanProgress
    include Writable

    def initialize(@files : Int64, @hashed_bytes : Int64) : Nil
    end

    getter files : Int64
    getter hashed_bytes : Int64

    def tag : Tag
      Tag::ScanProgress
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(files, FORMAT)
      io.write_bytes(hashed_bytes, FORMAT)
    end
  end
end
