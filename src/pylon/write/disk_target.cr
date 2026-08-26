require "../scan/metadata"

module Pylon::Write
  struct PosixTarget
    TEMPORARY_PREFIX = ".pylon-tmp-"

    def initialize(@root : String)
    end

    def metadata(relative_path : String) : Scan::Metadata?
      Scan::Metadata.of(absolute(relative_path))
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
      path = absolute(relative_path)

      staged(path) do |temporary|
        File.write(temporary, content)
        File.chmod(temporary, executable ? 0o755 : 0o644)
      end
    end

    def create_symlink(relative_path : String, target : String) : Bool
      path = absolute(relative_path)

      staged(path) do |temporary|
        File.symlink(target, temporary)
      end
    end

    def set_executable(relative_path : String, executable : Bool) : Bool
      path = absolute(relative_path)
      mode = Scan::Metadata.of(path).try(&.mode)
      return false if mode.nil?

      permissions = (mode & 0o7777_u32)
      permissions = if executable
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
