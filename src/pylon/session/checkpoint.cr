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
      File.open(path, "rb") { |io| read(io) }
    rescue File::NotFoundError
      Absent.new
    rescue error : File::Error
      Damaged.new(error.message || error.class.name)
    end

    private def self.read(io : IO) : Checkpoint | Damaged
      loaded = Wire::Truncated.contain do
        magic = Bytes.new(MAGIC.bytesize)
        io.read_fully(magic)
        next Damaged.new("not a pylon state file") unless String.new(magic) == MAGIC
        next Damaged.new("written by a different pylon version") unless io.read_bytes(UInt32, Wire::FORMAT) == VERSION
        next Damaged.new("unknown digest algorithm") unless Wire::Binary.read_string(io) == DIGEST

        new(
          base: Wire::Binary.read_entry(io),
          local_cache: Wire::Binary.read_cache(io),
          remote_cache: Wire::Binary.read_cache(io),
        )
      end

      loaded.is_a?(Wire::Invalid) ? Damaged.new(loaded.reason) : loaded
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
      Dir.mkdir_p(File.dirname(path))
      temporary = "#{path}.#{Random::Secure.hex(8)}"

      File.open(temporary, "wb") do |io|
        io.write(MAGIC.to_slice)
        io.write_bytes(VERSION, Wire::FORMAT)
        Wire::Binary.write_string(io, DIGEST)
        Wire::Binary.write_entry(io, base)
        Wire::Binary.write_cache(io, local_cache)
        Wire::Binary.write_cache(io, remote_cache)
      end

      File.rename(temporary, path)
      nil
    rescue error : File::Error
      File.delete?(temporary) if temporary
      Damaged.new(error.message || error.class.name)
    end
  end
end
