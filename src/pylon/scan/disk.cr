require "digest/sha256"
require "./metadata"

module Pylon::Scan
  struct PosixFilesystem
    READ_BUFFER_BYTES = 64 * 1024

    def initialize(@root : String)
    end

    def metadata(relative_path : String) : Metadata?
      Metadata.of(absolute(relative_path))
    end

    def each_child(relative_path : String, & : String ->) : Nil
      Dir.each_child(absolute(relative_path)) { |name| yield name }
    end

    def digest(relative_path : String) : Bytes?
      digest = Digest::SHA256.new
      buffer = Bytes.new(READ_BUFFER_BYTES)

      File.open(absolute(relative_path)) do |file|
        while (read = file.read(buffer)) > 0
          digest.update(buffer[0, read])
        end
      end

      digest.final
    rescue File::Error
      nil
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
