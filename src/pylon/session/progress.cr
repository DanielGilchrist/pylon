require "./direction"

module Pylon::Session
  record Progress, direction : Direction, confirmed : Int32, total : Int32, total_bytes : UInt64?
end
