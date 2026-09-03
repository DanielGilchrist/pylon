require "../patch"
require "../binary"
require "../chunks"
require "./writable"

module Pylon::Wire::Message
  struct WriteResponse
    include Writable

    def initialize(@outcomes : Array(Write::Outcome)) : Nil
    end

    getter outcomes : Array(Write::Outcome)

    def tag : Tag
      Tag::WriteResponse
    end

    def write_payload(io : IO) : Nil
      Chunks.write_outcomes(io, outcomes)
    end
  end
end
