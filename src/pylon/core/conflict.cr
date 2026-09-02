require "./changes"

module Pylon::Core
  record Conflict, root : String, local_changes : Changes, remote_changes : Changes
end
