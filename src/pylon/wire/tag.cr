module Pylon::Wire
  enum Tag : UInt8
    Failure
    ScanRequest
    ScanResponse
    ContentsRequest
    ContentsResponse
    WriteRequest
    WriteResponse
    TreeUpdate
    TreeDelta
  end
end
