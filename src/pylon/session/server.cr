require "../wire/message"
require "./local_endpoint"

module Pylon::Session
  class Server
    def initialize(@endpoint : LocalEndpoint, @input : IO, @output : IO)
    end

    def run : Nil
      loop do
        break unless serve(Wire.read_message(@input))
      end
    rescue Wire::Truncated | IO::Error
      nil
    end

    private def serve(request : Wire::Message) : Bool
      case request
      in Wire::ScanRequest
        Wire::ScanResponse.new(@endpoint.scan(request.now_ns).root).write(@output)
      in Wire::ContentsRequest
        Wire::ContentsResponse.new(@endpoint.contents(request.digests)).write(@output)
      in Wire::WriteRequest
        Wire::WriteResponse.new(
          @endpoint.write(request.changes, request.contents)
        ).write(@output)
      in Wire::Failure, Wire::ScanResponse,
         Wire::ContentsResponse, Wire::WriteResponse
        Wire::Failure.new("unexpected message from the client").write(@output)
        return false
      end

      true
    end
  end
end
