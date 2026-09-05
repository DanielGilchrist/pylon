require "./error"
require "./lib_zstd"

module Pylon::Compress
  class Prefix
    LEVEL                =  9
    WINDOW_LOG_MIN       = 10
    WINDOW_LOG_MAX       = 27
    CONTENT_SIZE_UNKNOWN = UInt64::MAX
    CONTENT_SIZE_ERROR   = UInt64::MAX - 1

    def self.decompress(frame : Bytes, prefix : Bytes, limit : Int32) : Bytes | Error
      new.decompress(frame, prefix, limit)
    end

    def initialize : Nil
      @compressor = LibZstd.create_cctx
      @decompressor = LibZstd.create_dctx
    end

    def finalize : Nil
      LibZstd.free_cctx(@compressor)
      LibZstd.free_dctx(@decompressor)
    end

    def compress(source : Bytes, prefix : Bytes, into : Bytes) : Bytes | Error
      if (error = configure_compressor(window_log_for(source.size.to_i64 + prefix.size), prefix))
        return error
      end

      write_frame(source, into)
    end

    def decompress(frame : Bytes, prefix : Bytes, limit : Int32) : Bytes | Error
      size = declared_size(frame)
      if size == CONTENT_SIZE_UNKNOWN
        return Error.new("the frame does not declare its content size")
      end
      return Error.new("the frame header is invalid") if size == CONTENT_SIZE_ERROR
      if size > limit
        return Error.new("the frame claims #{size} bytes, over the #{limit} byte limit")
      end

      if (error = configure_decompressor(prefix))
        return error
      end

      read_frame(frame, Bytes.new(size.to_i32))
    end

    private def configure_compressor(window_log : Int32, prefix : Bytes) : Error?
      LibZstd.cctx_reset(@compressor, LibZstd::ResetDirective::SessionOnly)

      tune(LibZstd::CParameter::CompressionLevel, LEVEL) ||
        tune(LibZstd::CParameter::WindowLog, window_log) ||
        tune(
          LibZstd::CParameter::EnableLongDistanceMatching,
          window_log >= WINDOW_LOG_MAX ? 1 : 0,
        ) ||
        reference_for_compression(prefix)
    end

    private def configure_decompressor(prefix : Bytes) : Error?
      LibZstd.dctx_reset(@decompressor, LibZstd::ResetDirective::SessionOnly)

      Error.from_zstd(
        LibZstd.dctx_set_parameter(
          @decompressor,
          LibZstd::DParameter::WindowLogMax,
          WINDOW_LOG_MAX,
        ),
      ) ||
        reference_for_decompression(prefix)
    end

    private def window_log_for(span : Int64) : Int32
      (span - 1).bit_length.clamp(WINDOW_LOG_MIN, WINDOW_LOG_MAX)
    end

    private def tune(parameter : LibZstd::CParameter, value : Int32) : Error?
      Error.from_zstd(LibZstd.cctx_set_parameter(@compressor, parameter, value))
    end

    private def reference_for_compression(prefix : Bytes) : Error?
      Error.from_zstd(
        LibZstd.cctx_ref_prefix(
          @compressor,
          prefix.to_unsafe.as(Void*),
          LibC::SizeT.new(prefix.size),
        ),
      )
    end

    private def reference_for_decompression(prefix : Bytes) : Error?
      Error.from_zstd(
        LibZstd.dctx_ref_prefix(
          @decompressor,
          prefix.to_unsafe.as(Void*),
          LibC::SizeT.new(prefix.size),
        ),
      )
    end

    private def declared_size(frame : Bytes) : UInt64
      LibZstd.frame_content_size(frame.to_unsafe.as(Void*), LibC::SizeT.new(frame.size))
    end

    private def write_frame(source : Bytes, into : Bytes) : Bytes | Error
      written = LibZstd.compress2(
        @compressor,
        into.to_unsafe.as(Void*),
        LibC::SizeT.new(into.size),
        source.to_unsafe.as(Void*),
        LibC::SizeT.new(source.size),
      )

      Error.from_zstd(written) || into[0, written]
    end

    private def read_frame(frame : Bytes, into : Bytes) : Bytes | Error
      written = LibZstd.decompress_dctx(
        @decompressor,
        into.to_unsafe.as(Void*),
        LibC::SizeT.new(into.size),
        frame.to_unsafe.as(Void*),
        LibC::SizeT.new(frame.size),
      )

      Error.from_zstd(written) || into[0, written]
    end
  end
end
