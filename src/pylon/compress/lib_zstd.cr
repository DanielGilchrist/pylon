@[Link(pkg_config: "libzstd", lib: "zstd")]
lib LibZstd
  fun compress_bound = ZSTD_compressBound(src_size : LibC::SizeT) : LibC::SizeT
  fun is_error = ZSTD_isError(code : LibC::SizeT) : UInt32
  fun error_name = ZSTD_getErrorName(code : LibC::SizeT) : UInt8*

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
end
