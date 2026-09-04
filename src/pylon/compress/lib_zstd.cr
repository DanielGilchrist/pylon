@[Link(pkg_config: "libzstd", lib: "zstd")]
lib LibZstd
  type CCtx = Void*
  type DCtx = Void*

  enum CParameter
    CompressionLevel           = 100
    WindowLog                  = 101
    EnableLongDistanceMatching = 160
  end

  enum DParameter
    WindowLogMax = 100
  end

  enum ResetDirective
    SessionOnly = 1
  end

  fun compress_bound = ZSTD_compressBound(src_size : LibC::SizeT) : LibC::SizeT
  fun is_error = ZSTD_isError(code : LibC::SizeT) : UInt32
  fun error_name = ZSTD_getErrorName(code : LibC::SizeT) : UInt8*
  fun frame_content_size = ZSTD_getFrameContentSize(src : Void*, src_size : LibC::SizeT) : UInt64

  fun compress = ZSTD_compress(
    dst : Void*,
    dst_capacity : LibC::SizeT,
    src : Void*,
    src_size : LibC::SizeT,
    level : Int32,
  ) : LibC::SizeT

  fun decompress = ZSTD_decompress(
    dst : Void*,
    dst_capacity : LibC::SizeT,
    src : Void*,
    src_size : LibC::SizeT,
  ) : LibC::SizeT

  fun create_cctx = ZSTD_createCCtx : CCtx
  fun free_cctx = ZSTD_freeCCtx(cctx : CCtx) : LibC::SizeT
  fun cctx_reset = ZSTD_CCtx_reset(cctx : CCtx, reset : ResetDirective) : LibC::SizeT
  fun cctx_set_parameter = ZSTD_CCtx_setParameter(cctx : CCtx, parameter : CParameter, value : Int32) : LibC::SizeT
  fun cctx_ref_prefix = ZSTD_CCtx_refPrefix(cctx : CCtx, prefix : Void*, prefix_size : LibC::SizeT) : LibC::SizeT

  fun compress2 = ZSTD_compress2(
    cctx : CCtx,
    dst : Void*,
    dst_capacity : LibC::SizeT,
    src : Void*,
    src_size : LibC::SizeT,
  ) : LibC::SizeT

  fun create_dctx = ZSTD_createDCtx : DCtx
  fun free_dctx = ZSTD_freeDCtx(dctx : DCtx) : LibC::SizeT
  fun dctx_reset = ZSTD_DCtx_reset(dctx : DCtx, reset : ResetDirective) : LibC::SizeT
  fun dctx_set_parameter = ZSTD_DCtx_setParameter(dctx : DCtx, parameter : DParameter, value : Int32) : LibC::SizeT
  fun dctx_ref_prefix = ZSTD_DCtx_refPrefix(dctx : DCtx, prefix : Void*, prefix_size : LibC::SizeT) : LibC::SizeT

  fun decompress_dctx = ZSTD_decompressDCtx(
    dctx : DCtx,
    dst : Void*,
    dst_capacity : LibC::SizeT,
    src : Void*,
    src_size : LibC::SizeT,
  ) : LibC::SizeT
end
