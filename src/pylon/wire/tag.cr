module Pylon::Wire
  enum Tag : UInt8
    Failure
    ScanRequest
    ScanResponse
    ContentsRequest
    ContentsResponse
    WriteRequest
    WriteResponse
    PollRequest
    PollResponse
    TreeUpdate
    TreeDelta
  end
end
