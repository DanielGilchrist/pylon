module Pylon::Compress
  module Codec
    abstract def compress(source : Bytes, into : Bytes) : Bytes | Problem
    abstract def decompress(frame : Bytes, into : Bytes) : Bytes | Problem
    abstract def bound(size : Int32) : Int32
  end
end
