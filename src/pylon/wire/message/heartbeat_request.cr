module Pylon::Wire::Message
  struct HeartbeatRequest
    include Writable

    def tag : Tag
      Tag::HeartbeatRequest
    end

    def write_payload(io : IO) : Nil
    end
  end
end
