require "./signature"

module Pylon::Wire
  module Delta
    record Based, base : Bytes, signature : Signature
  end
end
