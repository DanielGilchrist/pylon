require "../core/change"
require "./checksums"
require "./reader"
require "../core/entry"
require "../scan/cache_entry"
require "../write/writer"

module Pylon::Wire
  module Binary
    extend self

    PROBLEM_SKIP = 255_u8

    def write_bool(io : IO, value : Bool) : Nil
      io.write_byte(value ? 1_u8 : 0_u8)
    end

    def write_framed_size(io : IO, size : Int32?) : Nil
      io.write_bytes(size.nil? ? 0_u32 : size.to_u32 + 1, FORMAT)
    end

    def write_bytes(io : IO, value : Bytes?) : Nil
      write_framed_size(io, value.try(&.size))
      io.write(value) if value
    end

    def write_string(io : IO, value : String?) : Nil
      write_bytes(io, value.try(&.to_slice))
    end

    def write_digest(io : IO, digest : Bytes) : Nil
      io.write(digest)
    end

    def write_digests(io : IO, digests : Array(Bytes)) : Nil
      io.write_bytes(digests.size.to_u32, FORMAT)
      digests.each { |digest| write_digest(io, digest) }
    end

    def write_bases(io : IO, bases : Bases) : Nil
      io.write_bytes(bases.size.to_u32, FORMAT)

      bases.each do |wanted, base|
        write_digest(io, wanted)
        write_digest(io, base)
      end
    end

    def read_bases(reader : Reader) : Bases
      count = reader.count
      bases = Bases.new(initial_capacity: Wire.capacity_hint(count))
      reader.repeat(count) { bases[reader.digest] = reader.digest }
      bases
    end

    def write_entry(io : IO, entry : Core::Entry?) : Nil
      case entry
      in Nil
        io.write_byte(0_u8)
      in Core::Directory
        io.write_byte(1_u8)
        io.write_bytes(entry.contents.size.to_u32, FORMAT)

        entry.contents.each do |name, child|
          write_string(io, name)
          write_entry(io, child)
        end
      in Core::File
        io.write_byte(2_u8)
        write_digest(io, entry.digest)
        write_bool(io, entry.executable?)
      in Core::SymbolicLink
        io.write_byte(3_u8)
        write_string(io, entry.target)
      in Core::Untracked
        io.write_byte(4_u8)
      in Core::Problematic
        io.write_byte(5_u8)
        write_string(io, entry.problem)
      end
    end

    def read_entry(reader : Reader) : Core::Entry?
      stack = nil
      name = ""

      loop do
        entry : Core::Entry? = nil

        case reader.byte
        when 0
        when 1
          count = reader.count
          contents = Hash(String, Core::Entry).new(initial_capacity: Wire.capacity_hint(count))

          if count.zero?
            entry = Core::Directory.new(contents)
          else
            stack ||= Array(OpenDirectory).new
            stack << OpenDirectory.new(name, contents, count)
            name = reader.name
            next
          end
        when 2
          entry = Core::File.new(reader.digest, executable: reader.bool)
        when 3
          entry = Core::SymbolicLink.new(reader.required_string)
        when 4
          entry = Core::Untracked.new
        when 5
          entry = Core::Problematic.new(reader.required_string)
        else
          unless reader.failed?
            reader.fail("unknown entry kind in message, both sides must run the same version")
          end
          return
        end

        return if reader.failed?

        loop do
          if stack.nil? || stack.empty?
            return entry
          end

          if entry.nil?
            reader.fail("missing child entry in message") unless reader.failed?
            return
          end

          open = stack.last
          open.contents[name] = entry

          if open.remaining > 1
            stack[stack.size - 1] = open.copy_with(remaining: open.remaining - 1)
            name = reader.name
            break
          end

          stack.pop
          entry = Core::Directory.new(open.contents)
          name = open.name
        end

        return if reader.failed?
      end
    end

    def write_changes(io : IO, changes : Core::Changes) : Nil
      io.write_bytes(changes.size.to_u32, FORMAT)

      changes.each do |change|
        write_string(io, change.path)
        write_entry(io, change.old)
        write_entry(io, change.new)
      end
    end

    def read_changes(reader : Reader) : Core::Changes
      count = reader.count
      changes = Core::Changes.new(initial_capacity: Wire.capacity_hint(count))

      reader.repeat(count) do
        path = reader.path
        changes << Core::Change.new(path, read_entry(reader), read_entry(reader))
      end

      changes
    end

    def write_relocations(io : IO, relocations : Array(Core::Relocation)) : Nil
      io.write_bytes(relocations.size.to_u32, FORMAT)

      relocations.each do |relocation|
        write_string(io, relocation.from)
        write_string(io, relocation.to)
        write_entry(io, relocation.entry)
      end
    end

    def read_relocations(reader : Reader) : Array(Core::Relocation)
      count = reader.count
      relocations = Array(Core::Relocation).new(Wire.capacity_hint(count))

      reader.repeat(count) do
        from = reader.path
        to = reader.path
        entry = read_entry(reader)
        next if reader.failed?

        case (relocation = Core::Relocation.parse(from, to, entry))
        in Core::Relocation then relocations << relocation
        in Problem
          reader.fail("a relocation #{relocation.reason}")
        end
      end

      relocations
    end

    def write_outcomes(io : IO, outcomes : Array(Write::Outcome)) : Nil
      io.write_bytes(outcomes.size.to_u32, FORMAT)

      outcomes.each do |outcome|
        write_string(io, outcome.path)
        write_entry(io, outcome.entry)
        write_skipped(io, outcome.skipped)
      end
    end

    def read_outcomes(reader : Reader) : Array(Write::Outcome)
      count = reader.count
      outcomes = Array(Write::Outcome).new(Wire.capacity_hint(count))

      reader.repeat(count) do
        outcomes << Write::Outcome.new(reader.path, read_entry(reader), read_skipped(reader))
      end

      outcomes
    end

    def write_skipped(io : IO, skipped : Write::Skipped?) : Nil
      case skipped
      in Nil         then io.write_byte(0_u8)
      in Write::Skip then io.write_byte(skipped.value.to_u8 + 1)
      in Problem
        io.write_byte(PROBLEM_SKIP)
        write_string(io, skipped.reason)
      end
    end

    def read_skipped(reader : Reader) : Write::Skipped?
      byte = reader.byte
      return if byte.zero?
      return Problem.new(reader.required_string) if byte == PROBLEM_SKIP

      skip = Write::Skip.from_value?(byte.to_i32 - 1)
      return skip if skip

      return if reader.failed?

      reader.fail("unknown skip reason in message, both sides must run the same version")
    end

    def write_cache(io : IO, cache : Scan::Cache) : Nil
      io.write_bytes(cache.size.to_u32, FORMAT)

      cache.each do |path, entry|
        metadata = entry.metadata

        write_string(io, path)
        io.write_bytes(metadata.mode, FORMAT)
        io.write_bytes(metadata.size, FORMAT)
        io.write_bytes(metadata.mtime_ns, FORMAT)
        io.write_bytes(metadata.inode, FORMAT)
        write_digest(io, entry.digest)
        write_bool(io, entry.freshly_written?)
      end
    end

    def read_cache(reader : Reader) : Scan::Cache
      count = reader.count
      cache = Scan::Cache.new(initial_capacity: Wire.capacity_hint(count))

      reader.repeat(count) do
        path = reader.path

        metadata = Scan::Metadata.new(
          mode: reader.u32,
          size: reader.u64,
          mtime_ns: reader.i64,
          inode: reader.u64,
        )

        digest = reader.digest
        cache[path] = Scan::CacheEntry.new(metadata, digest, freshly_written: reader.bool)
      end

      cache
    end

    def read_digests(reader : Reader) : Array(Bytes)
      count = reader.count
      digests = Array(Bytes).new(Wire.capacity_hint(count))
      reader.repeat(count) { digests << reader.digest }
      digests
    end

    def read_checksums_map(reader : Reader) : Checksums::Map
      count = reader.count
      map = Checksums::Map.new(initial_capacity: Wire.capacity_hint(count))

      reader.repeat(count) do
        wanted = reader.digest
        checksums = read_checksums(reader)
        map[wanted] = checksums if checksums
      end

      map
    end

    def write_checksums_map(io : IO, map : Checksums::Map) : Nil
      io.write_bytes(map.size.to_u32, FORMAT)

      map.each do |wanted, checksums|
        write_digest(io, wanted)
        write_checksums(io, checksums)
      end
    end

    def read_checksums(reader : Reader) : Checksums?
      base = reader.digest
      block_size = reader.u32
      base_size = reader.u64

      unless Checksums.plausible?(block_size, base_size)
        reader.fail("a checksum list claims impossible dimensions")
        return
      end

      count = ((base_size + block_size - 1) // block_size).to_u32
      blocks = Array(Checksums::Block).new(Wire.capacity_hint(count))

      reader.repeat(count) do
        weak = reader.u32
        strong = Bytes.new(Checksums::STRONG_BYTES)
        reader.fill(strong)
        blocks << Checksums::Block.new(weak, strong)
      end

      return if reader.failed?

      Checksums.new(base, block_size.to_i32, base_size.to_i64, blocks)
    end

    def write_checksums(io : IO, checksums : Checksums) : Nil
      write_digest(io, checksums.base)
      io.write_bytes(checksums.block_size.to_u32, FORMAT)
      io.write_bytes(checksums.base_size.to_u64, FORMAT)

      checksums.blocks.each do |block|
        io.write_bytes(block.weak, FORMAT)
        io.write(block.strong)
      end
    end

    private record OpenDirectory,
      name : String,
      contents : Hash(String, Core::Entry),
      remaining : UInt32
  end
end
