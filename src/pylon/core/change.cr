require "./entry"
require "./paths"

module Pylon::Core
  struct Change
    def initialize(@path : String, @old : Entry?, @new : Entry?) : Nil
    end

    getter path : String
    getter old : Entry?
    getter new : Entry?
  end
end
