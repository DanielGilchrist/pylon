module Pylon::Session
  struct Checkpoint
    MAGIC   = "PYLON\0"
    VERSION = 5_u32
    DIGEST  = "sha256"

    def self.load(path : String) : Checkpoint | Missing | Problem
      Filesystem.open(path, "rb") { |io| read(io) }
    end

    private def self.read(io : IO) : Checkpoint | Problem
      reader = Wire::Reader.new(io)

      magic = reader.take(MAGIC.bytesize)
      return Problem.new("not a sync state file") if reader.failed? || String.new(magic) != MAGIC
      return Problem.new("written by a different version") if reader.u32 != VERSION
      return Problem.new("unknown digest algorithm") if reader.string? != DIGEST

      base = Wire::Binary.read_entry(reader)
      local_cache = Wire::Binary.read_cache(reader)
      shared_tree = Wire::Binary.read_entry(reader)

      return Problem.new(reader.reason) if reader.failed?

      new(base: base, local_cache: local_cache, shared_tree: shared_tree)
    end

    def initialize(
      @base : Core::Entry? = nil,
      @local_cache : Scan::Cache = Scan::Cache.new,
      @shared_tree : Core::Entry? = nil,
    ) : Nil
    end

    getter base : Core::Entry?
    getter local_cache : Scan::Cache
    getter shared_tree : Core::Entry?

    def save(path : String) : Problem?
      if (blocked = Filesystem.ensure_directory(File.dirname(path)))
        return Problem.new(blocked.reason)
      end

      temporary = "#{path}.#{Random::Secure.hex(8)}"

      written = Filesystem.open(temporary, "wb") do |io|
        io.write(MAGIC.to_slice)
        io.write_bytes(VERSION, Wire::FORMAT)
        Wire::Binary.write_string(io, DIGEST)
        Wire::Binary.write_entry(io, base)
        Wire::Binary.write_cache(io, local_cache)
        Wire::Binary.write_entry(io, shared_tree)
        nil
      end

      case written
      in Nil
      in Missing
        return Problem.new("the state directory vanished while saving")
      in Problem
        Filesystem.delete(temporary)
        return Problem.new(written.reason)
      end

      if (blocked = Filesystem.rename(temporary, path))
        Filesystem.delete(temporary)
        return Problem.new(blocked.reason)
      end

      nil
    end
  end
end
