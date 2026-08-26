module Pylon::Compress
  struct Error
    getter message : String

    def initialize(@message : String)
    end
  end
end
