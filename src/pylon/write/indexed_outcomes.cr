require "./outcome"

module Pylon::Write
  class IndexedOutcomes
    def initialize(@indices : Array(Int32), @outcomes : Array(Outcome)) : Nil
      @cursor = 0
    end

    def claim?(index : Int32) : Outcome?
      return unless @cursor < @indices.size && @indices[@cursor] == index

      claimed = @outcomes[@cursor]
      @cursor += 1

      claimed
    end
  end
end
