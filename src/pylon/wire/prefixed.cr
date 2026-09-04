require "./delta"

module Pylon::Wire
  struct Prefixed
    SMALLEST_FILE = 1024_u64

    alias Bases = Hash(Bytes, Bytes)

    def self.worthwhile?(size : UInt64) : Bool
      SMALLEST_FILE <= size <= Delta::LARGEST_DELTA_FILE
    end

    def initialize(@base : Bytes, @frame : Bytes) : Nil
    end

    getter base : Bytes
    getter frame : Bytes
  end
end
