require "./patch"
require "./binary"

module Pylon::Wire
  abstract struct ContentSource
    abstract def digests : Set(Bytes)
    abstract def contents : Contents
    abstract def write(io : IO) : Nil

    struct Materialised < ContentSource
      getter digests : Set(Bytes)
      getter contents : Contents

      def initialize(@contents : Contents) : Nil
        @digests = Set(Bytes).new(@contents.size)
        @contents.each_key { |digest| @digests << digest }
      end

      def write(io : IO) : Nil
        Chunks.write_contents(io, contents)
      end
    end

    struct Streaming < ContentSource
      getter digests : Set(Bytes)

      def initialize(@digests : Set(Bytes), @emit : Proc(IO, Nil), @materialise : Proc(Contents)) : Nil
      end

      def contents : Contents
        @materialise.call
      end

      def write(io : IO) : Nil
        io.write_bytes(@digests.size.to_u32, FORMAT)
        @emit.call(io)
      end
    end
  end
end
