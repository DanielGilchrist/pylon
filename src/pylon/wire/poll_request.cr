require "./contents"
require "./binary"
require "./writable"

module Pylon::Wire
  struct PollRequest
    include Writable

    def tag : Tag
      Tag::PollRequest
    end

    def write_payload(io : IO) : Nil
    end
  end
end
