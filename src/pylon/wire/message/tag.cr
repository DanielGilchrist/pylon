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
    TreeChanges
    ChecksumsRequest
    ChecksumsResponse
    Configure
    ScanProgress
    TreeAnnounce
    ReusableRequest
    ReusableResponse
  end
end
