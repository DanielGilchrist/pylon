module Pylon::Session
  class MeteredReader < IO
    def initialize(@inner : IO, @inbound : Inbound) : Nil
    end

    def read(slice : Bytes) : Int32
      filled = @inner.read(slice)
      @inbound.arrived(filled)
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
