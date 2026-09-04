require "./lib_zstd"

module Pylon::Compress
  struct Error
    def self.from_zstd(code : LibC::SizeT) : Error?
      return if LibZstd.is_error(code) == 0

      new(String.new(LibZstd.error_name(code)))
    end

    def initialize(@message : String) : Nil
    end

    getter message : String
  end
end
