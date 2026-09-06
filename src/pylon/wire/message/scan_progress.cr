module Pylon::Wire::Message
  struct ScanProgress
    include Writable

    def initialize(@files : Int64, @bytes : Int64) : Nil
    end

    getter files : Int64
    getter bytes : Int64

    def tag : Tag
      Tag::ScanProgress
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(files, FORMAT)
      io.write_bytes(bytes, FORMAT)
    end
  end
end
