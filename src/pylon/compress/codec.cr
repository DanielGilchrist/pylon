require "./error"

module Pylon::Compress
  module Codec
    abstract def compress(source : Bytes, into : Bytes) : Bytes | Error
    abstract def decompress(frame : Bytes, into : Bytes) : Bytes | Error
    abstract def bound(size : Int32) : Int32
  end
end
