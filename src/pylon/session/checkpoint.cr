require "../scan/snapshot"
require "../wire/binary"

module Pylon::Session
  struct Checkpoint
    MAGIC   = "PYLON\0"
    VERSION = 1_u32
    DIGEST  = "sha256"

    def self.load(path : String) : Checkpoint?
      File.open(path, "rb") do |io|
        magic = Bytes.new(MAGIC.bytesize)
        io.read_fully(magic)
        return nil unless String.new(magic) == MAGIC
        return nil unless io.read_bytes(UInt32, Wire::FORMAT) == VERSION
        return nil unless Wire::Binary.read_string(io) == DIGEST

        new(
          base: Wire::Binary.read_entry(io),
          local_cache: Wire::Binary.read_cache(io),
          remote_cache: Wire::Binary.read_cache(io),
        )
      end
    rescue File::Error | IO::EOFError | Wire::Truncated
      nil
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

    def save(path : String) : Bool
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
      true
    rescue File::Error
      File.delete?(temporary) if temporary
      false
    end
  end
end
