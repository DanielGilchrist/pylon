module Pylon::Wire
  FORMAT            = IO::ByteFormat::LittleEndian
  DIGEST_BYTES      = 32
  MAX_FIELD_BYTES   = 1 << 20
  CAPACITY_HINT_CAP = 4096

  def self.capacity_hint(count : UInt32) : Int32
    Math.min(count, CAPACITY_HINT_CAP).to_i32
  end
end
