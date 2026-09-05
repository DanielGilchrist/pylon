module Pylon::Core
  record Reconciliation,
    base_changes : Changes,
    local_changes : Changes,
    remote_changes : Changes,
    conflicts : Array(String),
    troubles : Array(Trouble)
end
