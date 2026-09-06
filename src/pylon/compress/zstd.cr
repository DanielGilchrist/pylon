module Pylon::Compress
  struct Zstd
    include Codec

    DEFAULT_LEVEL = 1

    def self.bound(size : Int32) : Int32
      LibZstd.compress_bound(LibC::SizeT.new(size)).to_i32
    end

    def initialize(@level : Int32 = DEFAULT_LEVEL) : Nil
    end

    def compress(source : Bytes, into : Bytes) : Bytes | Problem
      written = LibZstd.compress(
        into.to_unsafe.as(Void*),
        LibC::SizeT.new(into.size),
        source.to_unsafe.as(Void*),
        LibC::SizeT.new(source.size),
        @level,
      )

      Compress.check(written) || into[0, written]
    end

    def decompress(frame : Bytes, into : Bytes) : Bytes | Problem
      written = LibZstd.decompress(
        into.to_unsafe.as(Void*),
        LibC::SizeT.new(into.size),
        frame.to_unsafe.as(Void*),
        LibC::SizeT.new(frame.size),
      )

      Compress.check(written) || into[0, written]
    end

    def bound(size : Int32) : Int32
      Zstd.bound(size)
    end
  end
end
