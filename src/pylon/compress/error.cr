module Pylon::Compress
  struct Error
    getter message : String

    def initialize(@message : String) : Nil
    end
  end
end
