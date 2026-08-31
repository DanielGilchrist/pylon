require "./paths"
require "./name"
require "./malformed"

module Pylon::Core
  struct RelativePath
    ROOT = new("")

    getter value : String

    def self.parse(raw : String) : RelativePath | Malformed
      return ROOT if raw.empty?
      return Malformed.new(raw, "contains a NUL byte") if raw.includes?('\0')

      raw.split('/').each do |segment|
        problem = Name.problem(segment)
        return Malformed.new(raw, problem) if problem
      end

      new(raw)
    end

    protected def initialize(@value : String)
    end

    def root? : Bool
      @value.empty?
    end

    def join(name : Name) : RelativePath
      new(Paths.join(@value, name.value))
    end
  end
end
