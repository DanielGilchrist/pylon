module Pylon::Core
  struct Reconciliation
    getter base_changes : Array(Change)
    getter local_changes : Array(Change)
    getter remote_changes : Array(Change)
    getter conflicts : Array(Conflict)
    getter troubles : Array(Trouble)

    def initialize(
      @base_changes : Array(Change),
      @local_changes : Array(Change),
      @remote_changes : Array(Change),
      @conflicts : Array(Conflict),
      @troubles : Array(Trouble) = [] of Trouble,
    )
    end

  end
end
