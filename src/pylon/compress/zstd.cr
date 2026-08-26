require "./codec"
require "./lib_zstd"

module Pylon::Compress
  struct Zstd
    include Codec

    MINIMUM_VERSION = 10_400_u32
    DEFAULT_LEVEL   =          1

    def self.available? : Bool
      LibZstd.version_number >= MINIMUM_VERSION
    end

    def initialize(@level : Int32 = DEFAULT_LEVEL)
    end

    def compress(source : Bytes, into : Bytes) : Bytes | Error
      written = LibZstd.compress(
        into.to_unsafe.as(Void*),
        LibC::SizeT.new(into.size),
        source.to_unsafe.as(Void*),
        LibC::SizeT.new(source.size),
        @level,
      )

      failed(written) || into[0, written]
    end

    def decompress(frame : Bytes, into : Bytes) : Bytes | Error
      written = LibZstd.decompress(
        into.to_unsafe.as(Void*),
        LibC::SizeT.new(into.size),
        frame.to_unsafe.as(Void*),
        LibC::SizeT.new(frame.size),
      )

      failed(written) || into[0, written]
    end

    def bound(size : Int32) : Int32
      LibZstd.compress_bound(LibC::SizeT.new(size)).to_i32
    end

    private def failed(code : LibC::SizeT) : Error?
      return nil if LibZstd.is_error(code) == 0

      Error.new(String.new(LibZstd.error_name(code)))
    end
  end
end
