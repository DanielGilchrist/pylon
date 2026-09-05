module Pylon::Wire
  struct Checksums
    record Block, weak : UInt32, strong : Bytes
  end
end
