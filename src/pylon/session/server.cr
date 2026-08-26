require "sync"
require "../watch/subscriber"
require "../wire/message"
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
      @lock = Sync::Mutex.new
      @stopping = false
    end

    def run : Nil
      announce

      loop do
        break unless serve(Wire.read_message(@input))
      end
    rescue Wire::Truncated | IO::Error
      nil
    ensure
      @stopping = true
      @persister.try(&.flush)
    end

    private def announce : Nil
      subscriber = @subscriber
      return if subscriber.nil?

      push

      spawn do
        until @stopping
          subscriber.signals.receive?
          push
        end
      end
    end

    private def push : Nil
      @lock.synchronize do
        drain
        Wire::TreeUpdate.new(@endpoint.scan(Time.utc.to_unix_ns.to_i64).root).write(@output)
      end
    rescue IO::Error
      nil
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
        @lock.synchronize do
          drain
          Wire::ScanResponse.new(@endpoint.scan(request.now_ns).root).write(@output)
        end
      in Wire::ContentsRequest
        @lock.synchronize do
          Wire::ContentsResponse.new(@endpoint.content_source(request.digests, request.budget).contents).write(@output)
        end
      in Wire::WriteRequest
        @lock.synchronize do
          outcomes = @endpoint.write(request.changes, Wire::ContentSource.materialised(request.contents))
          Wire::WriteResponse.new(outcomes).write(@output)
          @persister.try(&.maybe)
        end
      in Wire::PollRequest
        @lock.synchronize do
          Wire::PollResponse.new(@subscriber.try(&.pending?) != false).write(@output)
        end
      in Wire::Failure, Wire::ScanResponse, Wire::PollResponse, Wire::TreeUpdate,
         Wire::ContentsResponse, Wire::WriteResponse
        @lock.synchronize do
          Wire::Failure.new("unexpected message from the client").write(@output)
        end

        return false
      end

      true
    end
  end
end
