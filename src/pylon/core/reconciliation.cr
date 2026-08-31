module Pylon::Core
  record Reconciliation,
    base_changes : Array(Change),
    local_changes : Array(Change),
    remote_changes : Array(Change),
    conflicts : Array(Conflict),
    troubles : Array(Trouble) = [] of Trouble
end
