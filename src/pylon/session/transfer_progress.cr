module Pylon::Session
  record TransferProgress, into : Replica, confirmed : Int32, total : Int32, total_bytes : UInt64?
end
