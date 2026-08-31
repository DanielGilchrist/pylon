require "../problem"

module Pylon
  module Filesystem
    struct Pattern
      def self.parse(text : String) : Pattern | Problem
        # stdlibs `File.match?` reports a malformed glob by throwing an exception.
        # We want to avoid exceptions as they can leave the application in undesirable
        # states but also make potential failures invisible to the type system.
        text.split('/').each do |segment|
          ::File.match?(segment, "x")
        rescue error : File::BadPatternError
          return Problem.new(error.message || "bad pattern")
        end

        new(text)
      end

      private def initialize(@text : String)
      end

      getter text : String

      def matches?(path : String) : Bool
        File.match?(@text, path) || File.match?("#{@text}/**", path)
      end
    end
  end
end
