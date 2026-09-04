module Pylon::Session
  class Meter
    def initialize : Nil
      @bytes = Atomic(Int64).new(0)
    end

    def add(count : Int32) : Nil
      @bytes.add(count.to_i64)
    end

    def bytes : Int64
      @bytes.get
    end
  end
end
