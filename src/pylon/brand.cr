module Pylon
  struct Brand
    DEFAULT = new("pylon")

    getter name : String

    def initialize(@name : String) : Nil
    end

    def prefix(message : String) : String
      "#{@name}: #{message}"
    end
  end
end
