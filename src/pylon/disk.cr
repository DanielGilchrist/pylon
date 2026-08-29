require "digest/sha256"
require "file_utils"
require "./wire/chunks"
require "./wire/binary"
require "./scan/metadata"

module Pylon
  struct Disk
    READ_BUFFER_BYTES = 64 * 1024
    TEMPORARY_PREFIX  = ".pylon-tmp-"

    def initialize(@root : String)
    end

    def metadata(relative_path : String) : Scan::Metadata?
      Scan::Metadata.of(absolute(relative_path))
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
      Wire::Binary.write_bytes(io, digest)
      streamed = Digest::SHA256.new

      File.open(absolute(relative_path)) do |file|
        while (read = file.read(buffer)) > 0
          streamed.update(buffer[0, read])
          Wire::Chunks.write_chunk(io, buffer[0, read], codec, scratch)
        end
      end

      Wire::Chunks.write_end(io, valid: streamed.final == digest)
    rescue File::Error
      Wire::Chunks.write_end(io, valid: false)
    end

    def link_target(relative_path : String) : String?
      File.readlink(absolute(relative_path))
    rescue File::Error
      nil
    end

    def create_directory(relative_path : String) : Bool
      path = absolute(relative_path)
      return true if Dir.exists?(path)

      Dir.mkdir_p(path)
      true
    rescue File::Error
      false
    end

    def write_file(relative_path : String, content : Bytes, executable : Bool) : Bool
      staged(absolute(relative_path)) do |temporary|
        File.write(temporary, content)
        File.chmod(temporary, executable ? 0o755 : 0o644)
      end
    end

    def create_symlink(relative_path : String, target : String) : Bool
      staged(absolute(relative_path)) do |temporary|
        File.symlink(target, temporary)
      end
    end

    def set_executable(relative_path : String, executable : Bool) : Bool
      path = absolute(relative_path)
      mode = Scan::Metadata.of(path).try(&.mode)
      return false if mode.nil?

      permissions = (mode & 0o7777_u32)
      permissions =
        if executable
          permissions | ((permissions & 0o444_u32) >> 2)
        else
          permissions & ~0o111_u32
        end

      File.chmod(path, permissions.to_i32)
      true
    rescue File::Error
      false
    end

    def remove(relative_path : String) : Bool
      path = absolute(relative_path)
      info = File.info?(path, follow_symlinks: false)
      return true if info.nil?

      info.directory? ? FileUtils.rm_rf(path) : File.delete(path)
      true
    rescue File::Error
      false
    end

    private def staged(path : String, & : String ->) : Bool
      temporary = File.join(File.dirname(path), "#{TEMPORARY_PREFIX}#{Random::Secure.hex(8)}")

      begin
        yield temporary
        File.rename(temporary, path)
        true
      rescue File::Error
        File.delete?(temporary)
        false
      end
    end

    private def absolute(relative_path : String) : String
      relative_path.empty? ? @root : File.join(@root, relative_path)
    end
  end
end
