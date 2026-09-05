module Pylon
  class Progress
    def initialize : Nil
      @files = Atomic(Int64).new(0)
      @bytes = Atomic(Int64).new(0)
      @finished = Atomic(Int32).new(0)
    end

    def reset : Nil
      @files.set(0)
      @bytes.set(0)
      @finished.set(0)
    end

    def add_file : Nil
      @files.add(1)
    end

    def add_bytes(count : Int64) : Nil
      @bytes.add(count)
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

    def bytes : Int64
      @bytes.get
    end
  end
end
