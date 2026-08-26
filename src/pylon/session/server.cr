require "../wire/message"
require "../watch/subscriber"
require "./local_endpoint"
require "./persister"

module Pylon::Session
  class Server
    def initialize(
      @endpoint : LocalEndpoint,
      @input : IO,
      @output : IO,
      @subscriber : Watch::Subscriber? = nil,
      @persister : Persister? = nil,
    )
    end

    def run : Nil
      loop do
        break unless serve(Wire.read_message(@input))
      end
    rescue Wire::Truncated | IO::Error
      nil
    ensure
      @persister.try(&.flush)
    end

    private def drain : Nil
      subscriber = @subscriber
      return if subscriber.nil?

      changes = subscriber.drain
      changes.fresh ? @endpoint.invalidate : @endpoint.mark_dirty(changes.paths)
    end

    private def serve(request : Wire::Message) : Bool
      case request
      in Wire::ScanRequest
        drain
        Wire::ScanResponse.new(@endpoint.scan(request.now_ns).root).write(@output)
      in Wire::ContentsRequest
        Wire::ContentsResponse.new(@endpoint.contents(request.digests)).write(@output)
      in Wire::PollRequest
        Wire::PollResponse.new(@subscriber.try(&.pending?) != false).write(@output)
      in Wire::WriteRequest
        outcomes = @endpoint.write(request.changes, request.contents)
        Wire::WriteResponse.new(outcomes).write(@output)
        @persister.try(&.maybe)
      in Wire::Failure, Wire::ScanResponse, Wire::PollResponse,
         Wire::ContentsResponse, Wire::WriteResponse
        Wire::Failure.new("unexpected message from the client").write(@output)
        return false
      end

      true
    end
  end
end
