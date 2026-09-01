require "./contents"
require "./binary"

module Pylon::Wire
  abstract struct ContentSource
    abstract def digests : Set(Bytes)
    abstract def contents : Contents
    abstract def write(io : IO) : Nil

    struct Materialised < ContentSource
      getter digests : Set(Bytes)
      getter contents : Contents

      def initialize(@contents : Contents)
        @digests = Set(Bytes).new(@contents.size)
        @contents.each_key { |digest| @digests << digest }
      end

      def write(io : IO) : Nil
        Wire.write_contents(io, contents)
      end
    end

    struct Streaming < ContentSource
      getter digests : Set(Bytes)

      def initialize(@digests : Set(Bytes), @emit : Proc(IO, Nil), @materialise : Proc(Contents))
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
