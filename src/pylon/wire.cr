require "./wire/spliced"
require "./wire/dictionary"

module Pylon::Wire
  PROTOCOL = 10_u32
  IDENTITY = "PYLON"

  FORMAT            = IO::ByteFormat::LittleEndian
  DIGEST_BYTES      = 32
  MAX_FIELD_BYTES   = 1 << 20
  MAX_CONTENT_BYTES = 256 * 1024 * 1024
  CAPACITY_HINT_CAP = 4096

  alias Payload = Bytes | Spliced | Dictionary
  alias Contents = Hash(Bytes, Payload)
  alias Bases = Hash(Bytes, Bytes)

  def self.capacity_hint(count : UInt32) : Int32
    Math.min(count, CAPACITY_HINT_CAP).to_i32
  end
end
