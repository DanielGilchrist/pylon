module Pylon::Wire
  enum ContentKind : UInt8
    Full       = 0
    Spliced    = 1
    Dictionary = 2

    def write(io : IO) : Nil
      io.write_byte(value)
    end
  end
end
