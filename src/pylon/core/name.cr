module Pylon::Core
  struct Name
    def self.parse(raw : String) : Name | Problem
      problem = self.problem(raw)
      problem ? Problem.new(problem) : new(raw)
    end

    def self.problem(raw : String) : String?
      return "is empty" if raw.empty?
      return "is a path component with a NUL byte" if raw.includes?('\0')
      return "is a path component with a '/'" if raw.includes?('/')
      return "is a '.' path component" if raw == "."
      return "is a '..' path component" if raw == ".."

      nil
    end

    protected def initialize(@value : String) : Nil
    end

    getter value : String
  end
end
