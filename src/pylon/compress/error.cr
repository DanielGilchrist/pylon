module Pylon::Compress
  struct Error
    def initialize(@message : String) : Nil
    end

    getter message : String
  end
end
