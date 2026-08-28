module Pylon::Session
  enum Direction
    ToLocal
    ToRemote
  end

  record Progress, direction : Direction, confirmed : Int32, total : Int32
end
