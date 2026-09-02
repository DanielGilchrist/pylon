require "./paths"
require "./name"
require "./malformed"

module Pylon::Core
  struct RelativePath
    ROOT                = new("")
    PATH_SEPARATOR_BYTE = '/'.ord.to_u8

    getter value : String

    def self.parse(raw : String) : RelativePath | Malformed
      return ROOT if raw.empty?
      return Malformed.new(raw, "contains a NUL byte") if raw.includes?('\0')

      bytes = raw.to_slice
      start = 0

      while start <= bytes.size
        separator = bytes.index(PATH_SEPARATOR_BYTE, start) || bytes.size
        length = separator - start

        if length == 0
          return Malformed.new(raw, "is empty")
        elsif length == 1 && bytes[start] == '.'.ord
          return Malformed.new(raw, "is a '.' path component")
        elsif length == 2 && bytes[start] == '.'.ord && bytes[start + 1] == '.'.ord
          return Malformed.new(raw, "is a '..' path component")
        end

        start = separator + 1
      end

      new(raw)
    end

    protected def initialize(@value : String)
    end
  end
end
