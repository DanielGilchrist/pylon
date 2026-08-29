require "../compress/zstd"
require "./binary"

module Pylon::Wire
  module Chunks
    extend self

    CHUNK_BYTES = 64 * 1024

    def scratch : Bytes
      Bytes.new(Compress::Zstd.new.bound(CHUNK_BYTES))
    end

    def write_chunk(io : IO, source : Bytes, codec, scratch : Bytes) : Nil
      packed = codec.compress(source, scratch)
      raise Truncated.new("compression failed: #{packed.message}") if packed.is_a?(Compress::Error)

      io.write_bytes(packed.size.to_u32 + 1, FORMAT)
      io.write_bytes(source.size.to_u32, FORMAT)
      io.write(packed)
    end

    def write_end(io : IO, valid : Bool = true) : Nil
      io.write_bytes(0_u32, FORMAT)
      Binary.write_bool(io, valid)
    end

    def write_all(io : IO, content : Bytes, codec, scratch : Bytes) : Nil
      offset = 0

      while offset < content.size
        length = Math.min(CHUNK_BYTES, content.size - offset)
        write_chunk(io, content[offset, length], codec, scratch)
        offset += length
      end

      write_end(io)
    end

    def write_entry(io : IO, entry : Core::Entry?) : Nil
      packed = IO::Memory.new
      Binary.write_entry(packed, entry)
      write_all(io, packed.to_slice, Compress::Zstd.new, scratch)
    end

    def read_entry(io : IO) : Core::Entry?
      packed = read_all(io, Compress::Zstd.new, scratch)
      raise Truncated.new("the tree payload arrived invalidated") if packed.nil?

      Binary.read_entry(IO::Memory.new(packed))
    end

    def read_all(io : IO, codec, scratch : Bytes) : Bytes?
      collected = IO::Memory.new

      loop do
        packed_size = io.read_bytes(UInt32, FORMAT)
        break if packed_size == 0

        raw_size = io.read_bytes(UInt32, FORMAT)
        packed = scratch[0, packed_size - 1]
        io.read_fully(packed)

        unpacked = codec.decompress(packed, Bytes.new(raw_size))
        raise Truncated.new("decompression failed: #{unpacked.message}") if unpacked.is_a?(Compress::Error)

        collected.write(unpacked)
      end

      return nil unless Binary.read_bool(io)

      collected.to_slice
    end
  end
end
