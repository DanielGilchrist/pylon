require "digest/sha256"
require "file_utils"
require "./wire/chunks"
require "./wire/binary"
require "./scan/metadata"
require "./write/problem"

module Pylon
  struct Disk
    READ_BUFFER_BYTES = 64 * 1024
    TEMPORARY_PREFIX  = ".pylon-tmp-"

    def initialize(@root : String)
    end

    def metadata(relative_path : String) : Scan::Metadata | Problem | Nil
      Scan::Metadata.of(absolute(relative_path))
    end

    def each_child(relative_path : String, & : String ->) : Nil
      Dir.each_child(absolute(relative_path)) { |name| yield name }
    end

    def digest(relative_path : String, buffer : Bytes = Bytes.new(READ_BUFFER_BYTES)) : Bytes | Problem
      digest = Digest::SHA256.new

      File.open(absolute(relative_path)) do |file|
        while (read = file.read(buffer)) > 0
          digest.update(buffer[0, read])
        end
      end

      digest.final
    rescue error : File::Error
      problem(error)
    end

    def read(relative_path : String) : Bytes | Problem
      File.open(absolute(relative_path)) do |file|
        buffer = Bytes.new(file.size)
        file.read_fully(buffer)
        buffer
      end
    rescue error : File::Error | IO::EOFError
      Problem.new(error.message || error.class.name)
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

    def link_target(relative_path : String) : String | Problem
      File.readlink(absolute(relative_path))
    rescue error : File::Error
      problem(error)
    end

    def create_directory(relative_path : String) : Write::Problem?
      path = absolute(relative_path)
      return nil if Dir.exists?(path)

      Dir.mkdir_p(path)
      nil
    rescue error : File::Error
      problem(error)
    end

    def write_file(relative_path : String, content : Bytes, executable : Bool) : Write::Problem?
      staged(absolute(relative_path)) do |temporary|
        File.write(temporary, content)
        File.chmod(temporary, executable ? 0o755 : 0o644)
      end
    end

    def create_symlink(relative_path : String, target : String) : Write::Problem?
      staged(absolute(relative_path)) do |temporary|
        File.symlink(target, temporary)
      end
    end

    def set_executable(relative_path : String, executable : Bool) : Write::Problem?
      path = absolute(relative_path)

      case observed = Scan::Metadata.of(path)
      in Nil
        return Write::Problem.new("the permissions could not be read: the file is missing")
      in Problem
        return Write::Problem.new("the permissions could not be read: #{observed.reason}")
      in Scan::Metadata
      end

      permissions = (observed.mode & 0o7777_u32)
      permissions =
        if executable
          permissions | ((permissions & 0o444_u32) >> 2)
        else
          permissions & ~0o111_u32
        end

      File.chmod(path, permissions.to_i32)
      nil
    rescue error : File::Error
      problem(error)
    end

    def remove(relative_path : String) : Write::Problem?
      path = absolute(relative_path)
      info = File.info?(path, follow_symlinks: false)
      return nil if info.nil?

      info.directory? ? FileUtils.rm_rf(path) : File.delete(path)
      nil
    rescue error : File::Error
      problem(error)
    end

    private def staged(path : String, & : String ->) : Write::Problem?
      temporary = File.join(File.dirname(path), "#{TEMPORARY_PREFIX}#{Random::Secure.hex(8)}")

      begin
        yield temporary
        File.rename(temporary, path)
        nil
      rescue error : File::Error
        File.delete?(temporary)
        problem(error)
      end
    end

    private def problem(error : File::Error) : Write::Problem
      Write::Problem.new(error.message || error.class.name)
    end

    private def absolute(relative_path : String) : String
      relative_path.empty? ? @root : File.join(@root, relative_path)
    end
  end
end
