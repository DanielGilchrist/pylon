require "../filesystem"
require "../scan/snapshot"
require "../wire/binary"

module Pylon::Session
  struct Checkpoint
    MAGIC   = "PYLON\0"
    VERSION = 2_u32
    DIGEST  = "sha256"

    record Absent
    record Damaged, reason : String

    def self.load(path : String) : Checkpoint | Absent | Damaged
      case loaded = Filesystem.open(path, "rb") { |io| read(io) }
      in Missing             then Absent.new
      in Problem             then Damaged.new(loaded.reason)
      in Checkpoint, Damaged then loaded
      end
    end

    private def self.read(io : IO) : Checkpoint | Damaged
      reader = Wire::Reader.new(io)

      magic = reader.take(MAGIC.bytesize)
      return Damaged.new("not a pylon state file") if reader.failed? || String.new(magic) != MAGIC
      return Damaged.new("written by a different pylon version") if reader.u32 != VERSION
      return Damaged.new("unknown digest algorithm") if reader.string? != DIGEST

      base = Wire::Binary.read_entry(reader)
      local_cache = Wire::Binary.read_cache(reader)
      remote_cache = Wire::Binary.read_cache(reader)

      return Damaged.new(reader.reason) if reader.failed?

      new(base: base, local_cache: local_cache, remote_cache: remote_cache)
    end

    getter base : Core::Entry?
    getter local_cache : Scan::Cache
    getter remote_cache : Scan::Cache

    def initialize(
      @base : Core::Entry? = nil,
      @local_cache : Scan::Cache = Scan::Cache.new,
      @remote_cache : Scan::Cache = Scan::Cache.new,
    )
    end

    def save(path : String) : Damaged?
      if (blocked = Filesystem.ensure_directory(File.dirname(path)))
        return Damaged.new(blocked.reason)
      end

      temporary = "#{path}.#{Random::Secure.hex(8)}"

      written = Filesystem.open(temporary, "wb") do |io|
        io.write(MAGIC.to_slice)
        io.write_bytes(VERSION, Wire::FORMAT)
        Wire::Binary.write_string(io, DIGEST)
        Wire::Binary.write_entry(io, base)
        Wire::Binary.write_cache(io, local_cache)
        Wire::Binary.write_cache(io, remote_cache)
        nil
      end

      case written
      in Nil
      in Missing
        return Damaged.new("the state directory vanished while saving")
      in Problem
        Filesystem.delete(temporary)
        return Damaged.new(written.reason)
      end

      if (blocked = Filesystem.rename(temporary, path))
        Filesystem.delete(temporary)
        return Damaged.new(blocked.reason)
      end

      nil
    end
  end
end
