module Pylon::Core
  struct Trouble
    enum Side
      Local
      Remote
    end

    def initialize(@path : String, @side : Side, @reason : String) : Nil
    end

    getter path : String
    getter side : Side
    getter reason : String
  end
end
