module Pylon::Wire::Message
  struct HeartbeatResponse
    include Writable

    def tag : Tag
      Tag::HeartbeatResponse
    end

    def write_payload(io : IO) : Nil
    end
  end
end
