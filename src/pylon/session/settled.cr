require "./fault"

module Pylon::Session
  struct Settled(T)
    def initialize(@value : T) : Nil
    end

    def await : T | Fault
      @value
    end
  end
end
