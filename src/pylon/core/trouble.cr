module Pylon::Core
  struct Trouble
    enum Side
      Local
      Remote
    end

    getter path : String
    getter side : Side
    getter reason : String

    def initialize(@path : String, @side : Side, @reason : String) : Nil
    end
  end
end
