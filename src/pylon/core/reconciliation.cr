module Pylon::Core
  struct Reconciliation
    getter base_changes : Array(Change)
    getter local_changes : Array(Change)
    getter remote_changes : Array(Change)
    getter conflicts : Array(Conflict)

    def initialize(
      @base_changes : Array(Change),
      @local_changes : Array(Change),
      @remote_changes : Array(Change),
      @conflicts : Array(Conflict),
    )
    end

    def empty? : Bool
      base_changes.empty? &&
        local_changes.empty? &&
        remote_changes.empty? &&
        conflicts.empty?
    end
  end
end
