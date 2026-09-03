module Pylon::Watch
  alias Dirty = Everything | Touched

  record Everything

  record Touched, paths : Array(String)
end
