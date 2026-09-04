require "./meter"

module Pylon::Session
  class MeteredReader < IO
    def initialize(@inner : IO, @meter : Meter) : Nil
    end

    def read(slice : Bytes) : Int32
      filled = @inner.read(slice)
      @meter.add(filled)
      filled
    end

    def write(slice : Bytes) : Nil
      @inner.write(slice)
    end

    def closed? : Bool
      @inner.closed?
    end
  end
end
