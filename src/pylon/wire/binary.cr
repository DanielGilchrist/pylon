require "../core/change"
require "./reader"
require "../core/entry"
require "../scan/cache_entry"
require "../write/writer"

module Pylon::Wire
  module Binary
    extend self

    def write_bool(io : IO, value : Bool) : Nil
      io.write_byte(value ? 1_u8 : 0_u8)
    end

    def write_bytes(io : IO, value : Bytes?) : Nil
      if value.nil?
        io.write_bytes(0_u32, FORMAT)
        return
      end

      io.write_bytes(value.size.to_u32 + 1, FORMAT)
      io.write(value)
    end

    def write_string(io : IO, value : String?) : Nil
      write_bytes(io, value.try(&.to_slice))
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
        write_bytes(io, entry.digest)
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
      case reader.byte
      when 0
        nil
      when 1
        count = reader.count
        contents = Hash(String, Core::Entry).new

        reader.repeat(count) do
          name = reader.name
          child = read_entry(reader)

          if child.nil?
            reader.fail("missing child entry in message") unless reader.failed?
            next
          end

          contents[name] = child
        end

        Core::Directory.new(contents)
      when 2
        Core::File.new(reader.digest, executable: reader.bool)
      when 3
        Core::SymbolicLink.new(reader.required_string)
      when 4
        Core::Untracked.new
      when 5
        Core::Problematic.new(reader.required_string)
      else
        reader.fail("unknown entry kind in message, both sides must run the same pylon version") unless reader.failed?
        nil
      end
    end

    def write_changes(io : IO, changes : Array(Core::Change)) : Nil
      io.write_bytes(changes.size.to_u32, FORMAT)

      changes.each do |change|
        write_string(io, change.path)
        write_entry(io, change.old)
        write_entry(io, change.new)
      end
    end

    def read_changes(reader : Reader) : Array(Core::Change)
      changes = Array(Core::Change).new

      reader.repeat(reader.count) do
        path = reader.path
        changes << Core::Change.new(path, read_entry(reader), read_entry(reader))
      end

      changes
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
      outcomes = Array(Write::Outcome).new

      reader.repeat(reader.count) do
        outcomes << Write::Outcome.new(reader.path, read_entry(reader), read_skipped(reader))
      end

      outcomes
    end

    def write_skipped(io : IO, skipped : Write::Skipped?) : Nil
      case skipped
      in Nil                         then io.write_byte(0_u8)
      in Write::ModificationDetected then io.write_byte(1_u8)
      in Write::UnknownState         then io.write_byte(2_u8)
      in Write::StagedContentMissing then io.write_byte(3_u8)
      in Write::DryRun               then io.write_byte(4_u8)
      in Write::WriteFailed
        io.write_byte(5_u8)
        write_string(io, skipped.reason)
      end
    end

    def read_skipped(reader : Reader) : Write::Skipped?
      case reader.byte
      when 0 then nil
      when 1 then Write::ModificationDetected.new
      when 2 then Write::UnknownState.new
      when 3 then Write::StagedContentMissing.new
      when 4 then Write::DryRun.new
      when 5 then Write::WriteFailed.new(reader.required_string)
      else
        reader.fail("unknown skip reason in message, both sides must run the same pylon version") unless reader.failed?
        nil
      end
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
        write_bytes(io, entry.digest)
      end
    end

    def read_cache(reader : Reader) : Scan::Cache
      cache = Scan::Cache.new

      reader.repeat(reader.count) do
        path = reader.path

        metadata = Scan::Metadata.new(
          mode: reader.u32,
          size: reader.u64,
          mtime_ns: reader.i64,
          inode: reader.u64,
        )

        cache[path] = Scan::CacheEntry.new(metadata, reader.digest)
      end

      cache
    end
  end
end
