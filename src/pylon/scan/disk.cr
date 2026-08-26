require "digest/sha256"
require "../wire/chunks"
require "../wire/binary"
require "./metadata"

module Pylon::Scan
  struct Disk
    READ_BUFFER_BYTES = 64 * 1024

    def initialize(@root : String)
    end

    def metadata(relative_path : String) : Metadata?
      Metadata.of(absolute(relative_path))
    end

    def each_child(relative_path : String, & : String ->) : Nil
      Dir.each_child(absolute(relative_path)) { |name| yield name }
    end

    def digest(relative_path : String, buffer : Bytes = Bytes.new(READ_BUFFER_BYTES)) : Bytes?
      digest = Digest::SHA256.new

      File.open(absolute(relative_path)) do |file|
        while (read = file.read(buffer)) > 0
          digest.update(buffer[0, read])
        end
      end

      digest.final
    rescue File::Error
      nil
    end

    def read(relative_path : String) : Bytes?
      File.open(absolute(relative_path)) do |file|
        buffer = Bytes.new(file.size)
        file.read_fully(buffer)
        buffer
      end
    rescue File::Error | IO::EOFError
      nil
    end

    def stream(relative_path : String, digest : Bytes, io : IO, buffer : Bytes, codec, scratch : Bytes) : Nil
      Pylon::Wire::Binary.write_bytes(io, digest)

      File.open(absolute(relative_path)) do |file|
        while (read = file.read(buffer)) > 0
          Pylon::Wire::Chunks.write_chunk(io, buffer[0, read], codec, scratch)
        end
      end

      Pylon::Wire::Chunks.write_end(io)
    rescue File::Error
      Pylon::Wire::Chunks.write_end(io)
    end

    def link_target(relative_path : String) : String?
      File.readlink(absolute(relative_path))
    rescue File::Error
      nil
    end

    private def absolute(relative_path : String) : String
      relative_path.empty? ? @root : File.join(@root, relative_path)
    end
  end
end
