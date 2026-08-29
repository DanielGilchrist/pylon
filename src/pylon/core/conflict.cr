module Pylon::Core
  struct Conflict
    getter root : String
    getter local_changes : Array(Change)
    getter remote_changes : Array(Change)

    def initialize(@root : String, @local_changes : Array(Change), @remote_changes : Array(Change))
    end
  end
end
