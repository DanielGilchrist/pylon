module Pylon::Scan
  class Tally
    def initialize : Nil
      @files = Atomic(Int64).new(0)
      @hashed_bytes = Atomic(Int64).new(0)
      @finished = Atomic(Int32).new(0)
    end

    def reset : Nil
      @files.set(0)
      @hashed_bytes.set(0)
      @finished.set(0)
    end

    def saw_file : Nil
      @files.add(1)
    end

    def hashed(bytes : Int64) : Nil
      @hashed_bytes.add(bytes)
    end

    def finish : Nil
      @finished.set(1)
    end

    def finished? : Bool
      @finished.get == 1
    end

    def files : Int64
      @files.get
    end

    def hashed_bytes : Int64
      @hashed_bytes.get
    end
  end
end
