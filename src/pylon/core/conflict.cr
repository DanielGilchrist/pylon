module Pylon::Core
  struct Conflict
    getter root : String
    getter local_changes : Array(Change)
    getter remote_changes : Array(Change)

    def initialize(@root : String, @local_changes : Array(Change), @remote_changes : Array(Change))
    end

    def ==(other : Conflict) : Bool
      root == other.root &&
        local_changes == other.local_changes &&
        remote_changes == other.remote_changes
    end
  end
end
