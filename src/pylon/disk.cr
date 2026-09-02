require "digest/sha256"
require "./filesystem"
require "./wire/chunks"
require "./wire/binary"
require "./wire/content_kind"
require "./scan/ignores"
require "./scan/metadata"
require "./scan/observed"
require "./write/problem"

module Pylon
  struct Disk
    READ_BUFFER_BYTES = 64 * 1024
    TEMPORARY_PREFIX  = Scan::Ignores::TEMPORARY_PREFIX

    def initialize(@root : String) : Nil
    end

    def metadata(relative_path : String) : Scan::Metadata | Problem | Nil
      Scan::Metadata.of(absolute(relative_path))
    end

    def observe(relative_path : String) : Scan::Observed | Problem | Nil
      case (found = Scan::Metadata.of(absolute(relative_path)))
      in Nil     then nil
      in Problem then found
      in Scan::Metadata
        case found.kind
        in .directory? then Scan::ObservedDirectory.new
        in .file?      then Scan::ObservedFile.new(found)
        in .untracked? then Scan::ObservedUntracked.new
        in .symbolic_link?
          case (target = Filesystem.readlink(absolute(relative_path)))
          in Problem then target
          in String  then Scan::ObservedLink.new(target)
          end
        end
      end
    end

    def each_child(relative_path : String, & : String ->) : Missing | Problem | Nil
      Filesystem.each_child(absolute(relative_path)) { |name| yield name }
    end

    def digest(relative_path : String, buffer : Bytes = Bytes.new(READ_BUFFER_BYTES), hasher : Digest::SHA256 = Digest::SHA256.new) : Bytes | Problem
      hasher.reset

      opened = Filesystem.open(absolute(relative_path)) do |file|
        while (read = file.read(buffer)) > 0
          hasher.update(buffer[0, read])
        end

        hasher.final
      end

      case opened
      in Missing        then Problem.new("the file vanished after the scan saw it")
      in Bytes, Problem then opened
      end
    end

    def read(relative_path : String) : Bytes | Problem
      opened = Filesystem.open(absolute(relative_path)) do |file|
        buffer = Bytes.new(file.size)
        file.read_fully(buffer)
        buffer
      end

      case opened
      in Missing        then Problem.new("the file vanished after the scan saw it")
      in Bytes, Problem then opened
      end
    end

    def stream(relative_path : String, digest : Bytes, io : IO, buffer : Bytes, codec : Compress::Codec, scratch : Bytes, hasher : Digest::SHA256 = Digest::SHA256.new) : Nil
      Wire::Binary.write_bytes(io, digest)
      Wire::ContentKind::Full.write(io)
      hasher.reset

      opened = Filesystem.open(absolute(relative_path)) do |file|
        while (read = file.read(buffer)) > 0
          hasher.update(buffer[0, read])
          Wire::Chunks.write_chunk(io, buffer[0, read], codec, scratch)
        end

        hasher.final == digest
      end

      case opened
      in Bool             then Wire::Chunks.write_end(io, valid: opened)
      in Missing, Problem then Wire::Chunks.write_end(io, valid: false)
      end
    end

    def link_target(relative_path : String) : String | Problem
      Filesystem.readlink(absolute(relative_path))
    end

    def create_directory(relative_path : String) : Write::Problem?
      path = absolute(relative_path)
      return if Dir.exists?(path)

      Filesystem.ensure_directory(path)
    end

    def write_file(relative_path : String, content : Bytes, executable : Bool) : Write::Problem?
      staged(absolute(relative_path)) do |temporary|
        Filesystem.write(temporary, content) || Filesystem.chmod(temporary, executable ? 0o755 : 0o644)
      end
    end

    def create_symlink(relative_path : String, target : String) : Write::Problem?
      staged(absolute(relative_path)) do |temporary|
        Filesystem.symlink(target, temporary)
      end
    end

    def set_executable(relative_path : String, executable : Bool) : Write::Problem?
      path = absolute(relative_path)

      case (observed = Scan::Metadata.of(path))
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

      Filesystem.chmod(path, permissions.to_i32)
    end

    def remove(relative_path : String) : Write::Problem?
      case (info = Filesystem.info(absolute(relative_path)))
      in Missing
        nil
      in Problem
        info
      in ::File::Info
        path = absolute(relative_path)
        info.directory? ? Filesystem.delete_tree(path) : Filesystem.delete(path)
      end
    end

    private def staged(path : String, & : String -> Problem?) : Write::Problem?
      temporary = File.join(File.dirname(path), "#{TEMPORARY_PREFIX}#{Random::Secure.hex(8)}")

      failed = yield temporary
      failed ||= Filesystem.rename(temporary, path)
      return if failed.nil?

      case (discarded = Filesystem.delete(temporary))
      in Nil     then failed
      in Problem then Problem.new("#{failed.reason} (and the temporary file #{temporary} could not be removed: #{discarded.reason})")
      end
    end

    private def absolute(relative_path : String) : String
      relative_path.empty? ? @root : File.join(@root, relative_path)
    end
  end
end
