require "../replica"

module Pylon::Core
  struct Trouble
    def initialize(@path : String, @replica : Replica, @reason : String) : Nil
    end

    getter path : String
    getter replica : Replica
    getter reason : String
  end
end
