require "./wire/patch"

module Pylon::Wire
  PROTOCOL = 5_u32
  IDENTITY = "PYLON"

  FORMAT            = IO::ByteFormat::LittleEndian
  DIGEST_BYTES      = 32
  MAX_FIELD_BYTES   = 1 << 20
  MAX_CONTENT_BYTES = 256 * 1024 * 1024
  CAPACITY_HINT_CAP = 4096

  alias Payload = Bytes | Patch
  alias Contents = Hash(Bytes, Payload)

  def self.capacity_hint(count : UInt32) : Int32
    Math.min(count, CAPACITY_HINT_CAP).to_i32
  end
end
