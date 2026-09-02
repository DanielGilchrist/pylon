module Pylon::Core
  record Reconciliation,
    base_changes : Changes,
    local_changes : Changes,
    remote_changes : Changes,
    conflicts : Array(Conflict),
    troubles : Array(Trouble) = Array(Trouble).new
end
