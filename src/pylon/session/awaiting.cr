module Pylon::Session
  struct Awaiting(M, T)
    def initialize(@endpoint : RemoteEndpoint, @replies : Channel(M), @fault : Fault?) : Nil
    end

    def await : T | Fault
      if (fault = @fault)
        return fault
      end

      case (reply = @endpoint.receive(@replies))
      in Fault then reply
      in M     then reply.payload
      end
    end
  end
end
