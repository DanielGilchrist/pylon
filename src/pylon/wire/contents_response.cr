require "./contents"
require "./binary"
require "./writable"

module Pylon::Wire
  struct ContentsResponse
    include Writable

    getter contents : Contents

    def initialize(@contents : Contents)
    end

    def tag : Tag
      Tag::ContentsResponse
    end

    def write_payload(io : IO) : Nil
      Wire.write_contents(io, contents)
    end
  end
end
