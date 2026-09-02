struct Pylon::CLI
  struct Target
    struct Invalid
      getter message : String

      def initialize(@message : String) : Nil
      end
    end

    def self.parse(specification : String) : Target | Invalid
      separator = specification.index(':')

      if separator.nil?
        return Invalid.new("remote target #{specification.inspect} needs the form user@host:/path")
      end

      host = specification[0, separator]
      path = specification[(separator + 1)..]

      return Invalid.new("remote target #{specification.inspect} is missing a host") if host.empty?
      return Invalid.new("remote target #{specification.inspect} is missing a path") if path.empty?

      if host.starts_with?('-')
        return Invalid.new("remote target #{specification.inspect} has a host starting with '-', which ssh would read as an option")
      end

      new(host, path)
    end

    getter host : String
    getter path : String

    def initialize(@host : String, @path : String) : Nil
    end
  end
end
