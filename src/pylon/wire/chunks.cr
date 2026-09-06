require "digest/sha256"

module Pylon::Wire
  module Chunks
    extend self

    CHUNK_BYTES = 64 * 1024

    def scratch : Bytes
      Bytes.new(Compress::Zstd.bound(CHUNK_BYTES))
    end

    def write_chunk(io : IO, source : Bytes, codec : Compress::Codec, scratch : Bytes) : Nil
      packed = pack(codec, source, scratch)

      Binary.write_framed_size(io, packed.size)
      io.write_bytes(source.size.to_u32, FORMAT)
      io.write(packed)
    end

    def write_end(io : IO, valid : Bool = true) : Nil
      Binary.write_framed_size(io, nil)
      Binary.write_bool(io, valid)
    end

    def write_all(io : IO, content : Bytes, codec : Compress::Codec, scratch : Bytes) : Nil
      offset = 0

      while offset < content.size
        length = Math.min(CHUNK_BYTES, content.size - offset)
        write_chunk(io, content[offset, length], codec, scratch)
        offset += length
      end

      write_end(io)
    end

    def write_entry(io : IO, entry : Core::Entry?) : Nil
      write_packed(io) { |packed| Binary.write_entry(packed, entry) }
    end

    def measure_entry(entry : Core::Entry?) : UInt32
      packed = IO::Memory.new
      write_entry(packed, entry)
      packed.size.to_u32
    end

    def read_entry(reader : Reader) : Core::Entry?
      read_packed(reader, "the tree payload") { |inner| Binary.read_entry(inner) }
    end

    def write_changes(io : IO, changes : Core::Changes) : Nil
      write_packed(io) { |packed| Binary.write_changes(packed, changes) }
    end

    def read_changes(reader : Reader) : Core::Changes
      found = read_packed(reader, "the changes payload") { |inner| Binary.read_changes(inner) }
      found || Core::Changes.new
    end

    def write_outcomes(io : IO, outcomes : Array(Write::Outcome)) : Nil
      write_packed(io) { |packed| Binary.write_outcomes(packed, outcomes) }
    end

    def write_relocations(io : IO, relocations : Array(Core::Relocation)) : Nil
      write_packed(io) { |packed| Binary.write_relocations(packed, relocations) }
    end

    def read_relocations(reader : Reader) : Array(Core::Relocation)
      found = read_packed(reader, "the relocations payload") do |inner|
        Binary.read_relocations(inner)
      end

      found || Array(Core::Relocation).new
    end

    def read_contents(reader : Reader) : Contents
      count = reader.count
      contents = Contents.new(initial_capacity: Wire.capacity_hint(count))
      codec = Compress::Zstd.new
      scratch = scratch()
      hasher = Digest::SHA256.new
      sum = Bytes.new(DIGEST_BYTES)

      reader.repeat(count) do
        digest = reader.digest

        case ContentKind.from_value?(reader.byte)
        in Nil
          reader.fail("an unknown content kind arrived, both sides must run the same version")
        in .full?
          content = read_all(reader, codec, scratch)
          next if content.nil?

          hasher.reset
          hasher.update(content)
          hasher.final(sum)

          contents[digest] = content if sum == digest
        in .spliced?
          base = reader.digest
          ops = read_all(reader, codec, scratch)
          next if ops.nil?

          contents[digest] = Spliced.new(base, ops)
        in .dictionary?
          base = reader.digest
          frame = read_all(reader, Compress::Identity.new, scratch)
          next if frame.nil?

          contents[digest] = Dictionary.new(base, frame)
        end
      end

      contents
    end

    def write_contents(io : IO, contents : Contents) : Nil
      io.write_bytes(contents.size.to_u32, FORMAT)
      codec = Compress::Zstd.new
      scratch = scratch()

      contents.each do |digest, payload|
        Binary.write_digest(io, digest)

        case payload
        in Bytes
          ContentKind::Full.write(io)
          write_all(io, payload, codec, scratch)
        in Spliced
          ContentKind::Spliced.write(io)
          Binary.write_digest(io, payload.base)
          write_all(io, payload.ops, codec, scratch)
        in Dictionary
          ContentKind::Dictionary.write(io)
          Binary.write_digest(io, payload.base)
          write_all(io, payload.frame, Compress::Identity.new, scratch)
        end
      end
    end

    def read_outcomes(reader : Reader) : Array(Write::Outcome)
      found = read_packed(reader, "the outcomes payload") { |inner| Binary.read_outcomes(inner) }
      found || Array(Write::Outcome).new
    end

    def read_all(
      reader : Reader,
      codec : Compress::Codec,
      scratch : Bytes,
      limit : Int32 = Wire::MAX_CONTENT_BYTES,
    ) : Bytes?
      content = Bytes.empty
      filled = 0

      loop do
        case (packed_size = reader.framed_size(scratch.size))
        in Nil
          break
        in Reader::Oversized
          reader.fail(
            "a chunk claims #{packed_size.claimed} packed bytes, over the #{scratch.size} limit",
          )
          break
        in Int32
        end

        raw_size = reader.u32

        if raw_size > CHUNK_BYTES
          reader.fail("a chunk claims #{raw_size} raw bytes, over the #{CHUNK_BYTES} limit")
          break
        end

        if filled + raw_size.to_i32 > limit
          reader.fail("a content item ran past the #{limit} byte sync limit, refusing to buffer it")
          break
        end

        packed = scratch[0, packed_size]
        reader.fill(packed)
        break if reader.failed?

        if content.size - filled < raw_size
          wanted = Math.max(content.size.to_i64 * 2, (filled + raw_size.to_i32).to_i64)
          grown = Bytes.new(Math.min(wanted, limit.to_i64).to_i32)
          content[0, filled].copy_to(grown)
          content = grown
        end

        unpacked = codec.decompress(packed, content[filled, raw_size])

        if unpacked.is_a?(Problem)
          reader.fail("decompression failed: #{unpacked.reason}")
          break
        end

        filled += unpacked.size
      end

      return if reader.failed?
      return unless reader.bool

      content[0, filled]
    end

    private def write_packed(io : IO, & : IO ->) : Nil
      packed = IO::Memory.new
      yield packed
      write_all(io, packed.to_slice, Compress::Zstd.new, scratch)
    end

    private def read_packed(reader : Reader, payload : String, & : Reader -> T) : T? forall T
      packed = read_all(reader, Compress::Zstd.new, scratch)
      return if reader.failed?

      if packed.nil?
        reader.fail("#{payload} arrived invalidated")
        return
      end

      inner = Reader.new(IO::Memory.new(packed))
      value = yield inner
      reader.fail(inner.reason) if inner.failed?

      value
    end

    private def pack(codec : Compress::Codec, source : Bytes, scratch : Bytes) : Bytes
      packed = codec.compress(source, scratch)

      # An error here is a bug where the caller built mismatched buffers so we want to blow up
      # loudly.
      if packed.is_a?(Problem)
        raise "compression into a bound-sized buffer failed, a caller passed mismatched buffers: " \
              "#{packed.reason}"
      end

      packed
    end
  end
end
