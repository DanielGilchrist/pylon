require "./contents"
require "./binary"
require "./writable"

module Pylon::Wire
  struct PollResponse
    include Writable

    getter? changed : Bool

    def initialize(@changed : Bool)
    end

    def tag : Tag
      Tag::PollResponse
    end

    def write_payload(io : IO) : Nil
      Binary.write_bool(io, changed?)
    end
  end
end
