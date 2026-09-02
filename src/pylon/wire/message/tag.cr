module Pylon::Wire::Message
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
    SignaturesRequest
    SignaturesResponse
  end
end
