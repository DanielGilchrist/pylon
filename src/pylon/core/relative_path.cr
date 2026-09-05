require "./paths"
require "./name"
require "../problem"

module Pylon::Core
  struct RelativePath
    ROOT                = new("")
    PATH_SEPARATOR_BYTE = '/'.ord.to_u8

    def self.parse(raw : String) : RelativePath | Problem
      return ROOT if raw.empty?
      return Problem.new("contains a NUL byte") if raw.includes?('\0')

      bytes = raw.to_slice
      start = 0

      while start <= bytes.size
        separator = bytes.index(PATH_SEPARATOR_BYTE, start) || bytes.size
        length = separator - start

        return Problem.new("is empty") if length == 0
        if length == 1 && bytes[start] == '.'.ord
          return Problem.new("is a '.' path component")
        end

        if length == 2 && bytes[start] == '.'.ord && bytes[start + 1] == '.'.ord
          return Problem.new("is a '..' path component")
        end

        start = separator + 1
      end

      new(raw)
    end

    protected def initialize(@value : String) : Nil
    end

    getter value : String
  end
end
