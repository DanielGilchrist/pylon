module Pylon::Session
  enum Direction
    ToLocal
    ToRemote
  end

  record Progress, direction : Direction, confirmed : Int32, total : Int32, total_bytes : UInt64?
end
