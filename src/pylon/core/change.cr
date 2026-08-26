module Pylon::Core
  struct Change
    getter path : String
    getter old : Entry?
    getter new : Entry?

    def initialize(@path : String, @old : Entry?, @new : Entry?)
    end

    def ==(other : Change) : Bool
      path == other.path &&
        Entry.equal?(old, other.old, true) &&
        Entry.equal?(new, other.new, true)
    end
  end
end
