require "../wire/binary"
require "./state"

module Pylon::Session
  module Store
    extend self

    MAGIC   = "PYLON\0"
    VERSION = 1_u32
    DIGEST  = "sha256"

    def save(path : String, state : State) : Bool
      Dir.mkdir_p(File.dirname(path))
      temporary = "#{path}.#{Random::Secure.hex(8)}"

      File.open(temporary, "wb") do |io|
        io.write(MAGIC.to_slice)
        io.write_bytes(VERSION, Wire::FORMAT)
        Wire::Binary.write_string(io, DIGEST)
        Wire::Binary.write_entry(io, state.base)
        Wire::Binary.write_cache(io, state.local_cache)
        Wire::Binary.write_cache(io, state.remote_cache)
      end

      File.rename(temporary, path)
      true
    rescue File::Error
      File.delete?(temporary) if temporary
      false
    end

    def load(path : String) : State?
      File.open(path, "rb") do |io|
        magic = Bytes.new(MAGIC.bytesize)
        io.read_fully(magic)
        return nil unless String.new(magic) == MAGIC
        return nil unless io.read_bytes(UInt32, Wire::FORMAT) == VERSION
        return nil unless Wire::Binary.read_string(io) == DIGEST

        State.new(
          base: Wire::Binary.read_entry(io),
          local_cache: Wire::Binary.read_cache(io),
          remote_cache: Wire::Binary.read_cache(io),
        )
      end
    rescue File::Error | IO::EOFError | Wire::Truncated
      nil
    end
  end
end
