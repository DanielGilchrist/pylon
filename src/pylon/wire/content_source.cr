module Pylon::Wire
  abstract struct ContentSource
    struct Materialised < ContentSource
      def initialize(@contents : Contents) : Nil
        @digests = Set(Bytes).new(@contents.size)
        @contents.each_key { |digest| @digests << digest }
      end

      getter digests : Set(Bytes)
      getter contents : Contents

      def write(io : IO) : Nil
        Chunks.write_contents(io, contents)
      end
    end

    abstract def digests : Set(Bytes)
    abstract def contents : Contents
    abstract def write(io : IO) : Nil
  end
end
