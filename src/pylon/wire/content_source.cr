require "./contents"
require "./binary"

module Pylon::Wire
  struct ContentSource
    STREAM_BUFFER_BYTES = 64 * 1024

    def self.materialised(contents : Contents) : ContentSource
      new(contents: contents, digests: contents.keys.to_set)
    end

    def initialize(
      @contents : Contents? = nil,
      @emit : Proc(IO, Nil)? = nil,
      @count : Int32 = 0,
      @materialise : Proc(Contents)? = nil,
      @digests : Set(Bytes) = Set(Bytes).new,
    )
    end

    def digests : Set(Bytes)
      @digests
    end

    def contents : Contents
      @contents || @materialise.try(&.call) || Contents.new
    end

    def write(io : IO) : Nil
      emit = @emit

      if emit.nil?
        Wire.write_contents(io, contents)
        return
      end

      io.write_bytes(@count.to_u32, FORMAT)
      emit.call(io)
    end
  end
end
