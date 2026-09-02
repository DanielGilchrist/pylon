require "../patch"
require "../binary"
require "../chunks"
require "./writable"

module Pylon::Wire::Message
  struct WriteResponse
    include Writable

    getter outcomes : Array(Write::Outcome)

    def initialize(@outcomes : Array(Write::Outcome))
    end

    def tag : Tag
      Tag::WriteResponse
    end

    def write_payload(io : IO) : Nil
      Chunks.write_outcomes(io, outcomes)
    end
  end
end
