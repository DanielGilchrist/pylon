require "./codec"

module Pylon::Compress
  struct Identity
    include Codec

    def compress(source : Bytes, into : Bytes) : Bytes | Error
      return Error.new("buffer too small") if into.size < source.size

      source.copy_to(into)
      into[0, source.size]
    end

    def decompress(frame : Bytes, into : Bytes) : Bytes | Error
      return Error.new("buffer too small") if into.size < frame.size

      frame.copy_to(into)
      into[0, frame.size]
    end

    def bound(size : Int32) : Int32
      size
    end
  end
end
