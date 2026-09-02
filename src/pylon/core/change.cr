require "./entry"
require "./paths"

module Pylon::Core
  struct Change
    getter path : String
    getter old : Entry?
    getter new : Entry?

    def initialize(@path : String, @old : Entry?, @new : Entry?)
    end
  end
end
