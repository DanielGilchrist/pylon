require "./contents"
require "./binary"
require "./writable"

module Pylon::Wire
  struct WriteRequest
    include Writable

    getter changes : Array(Core::Change)
    getter contents : Contents

    def initialize(@changes : Array(Core::Change), @contents : Contents)
    end

    def tag : Tag
      Tag::WriteRequest
    end

    def write_payload(io : IO) : Nil
      Binary.write_changes(io, changes)
      Wire.write_contents(io, contents)
    end
  end
end
