require "../patch"
require "../binary"
require "./writable"

module Pylon::Wire::Message
  struct Failure
    include Writable

    def initialize(@message : String) : Nil
    end

    getter message : String

    def tag : Tag
      Tag::Failure
    end

    def write_payload(io : IO) : Nil
      Binary.write_string(io, message)
    end
  end
end
