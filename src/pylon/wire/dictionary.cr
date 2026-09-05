require "./splice"

module Pylon::Wire
  struct Dictionary
    SMALLEST_FILE = 1024_u64

    def self.worthwhile?(size : UInt64) : Bool
      SMALLEST_FILE <= size <= Splice::LARGEST_FILE
    end

    def initialize(@base : Bytes, @frame : Bytes) : Nil
    end

    getter base : Bytes
    getter frame : Bytes
  end
end
