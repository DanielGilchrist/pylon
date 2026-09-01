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
      packed = pack(codec, source, scratch)

      Binary.write_framed_size(io, packed.size)
      io.write_bytes(source.size.to_u32, FORMAT)
      io.write(packed)
    end

    def write_end(io : IO, valid : Bool = true) : Nil
      Binary.write_framed_size(io, nil)
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

    def read_entry(reader : Reader) : Core::Entry?
      packed = read_all(reader, Compress::Zstd.new, scratch)
      return if reader.failed?

      if packed.nil?
        reader.fail("the tree payload arrived invalidated")
        return
      end

      inner = Reader.new(IO::Memory.new(packed))
      entry = Binary.read_entry(inner)
      reader.fail(inner.reason) if inner.failed?
      entry
    end

    def read_all(reader : Reader, codec, scratch : Bytes) : Bytes?
      content = Bytes.empty
      filled = 0

      loop do
        case packed_size = reader.framed_size(scratch.size)
        in Nil
          break
        in Reader::Oversized
          reader.fail("a chunk claims #{packed_size.claimed} packed bytes, over the #{scratch.size} limit")
          break
        in Int32
        end

        raw_size = reader.u32

        if raw_size > CHUNK_BYTES
          reader.fail("a chunk claims #{raw_size} raw bytes, over the #{CHUNK_BYTES} limit")
          break
        end

        packed = scratch[0, packed_size]
        reader.fill(packed)
        break if reader.failed?

        if content.size - filled < raw_size
          grown = Bytes.new(Math.max(content.size * 2, filled + raw_size.to_i32))
          content[0, filled].copy_to(grown)
          content = grown
        end

        unpacked = codec.decompress(packed, content[filled, raw_size])

        if unpacked.is_a?(Compress::Error)
          reader.fail("decompression failed: #{unpacked.message}")
          break
        end

        filled += unpacked.size
      end

      return if reader.failed?
      return unless reader.bool

      content[0, filled]
    end

    private def pack(codec, source : Bytes, scratch : Bytes) : Bytes
      packed = codec.compress(source, scratch)

      # An error here is a bug where the caller built mismatched buffers so we want to blow up loudly.
      raise "compression into a bound-sized buffer failed, a caller passed mismatched buffers: #{packed.message}" if packed.is_a?(Compress::Error)

      packed
    end
  end
end
