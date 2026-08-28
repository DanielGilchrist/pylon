module Pylon::Watch
  record Everything

  record Touched, paths : Array(String)

  alias Dirty = Everything | Touched
end
