module Pylon
  struct Brand
    DEFAULT = new("pylon")

    def initialize(@name : String) : Nil
    end

    getter name : String

    def prefix(message : String) : String
      "#{@name}: #{message}"
    end
  end
end
