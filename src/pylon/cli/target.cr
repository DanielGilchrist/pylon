require "../problem"

struct Pylon::CLI
  struct Target
    def self.parse(specification : String) : Target | Problem
      separator = specification.index(':')

      if separator.nil?
        return Problem.new("remote target #{specification.inspect} needs the form user@host:/path")
      end

      host = specification[0, separator]
      path = specification[(separator + 1)..]

      return Problem.new("remote target #{specification.inspect} is missing a host") if host.empty?
      return Problem.new("remote target #{specification.inspect} is missing a path") if path.empty?

      if host.starts_with?('-')
        return Problem.new(
          "remote target #{specification.inspect} has a host starting with '-', which ssh would " \
          "read as an option",
        )
      end

      new(host, path)
    end

    def initialize(@host : String, @path : String) : Nil
    end

    getter host : String
    getter path : String
  end
end
