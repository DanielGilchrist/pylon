require "./contents"
require "./binary"
require "./writable"

module Pylon::Wire
  struct Failure
    include Writable

    getter message : String

    def initialize(@message : String)
    end

    def tag : Tag
      Tag::Failure
    end

    def write_payload(io : IO) : Nil
      Binary.write_string(io, message)
    end
  end
end
