require "sync"
require "../watch/watcher"
require "../core/applier"
require "../core/differ"
require "../wire/message"
require "./local_endpoint"
require "./checkpoint/schedule"

module Pylon::Session
  class Server
    def initialize(
      @endpoint : LocalEndpoint,
      @input : IO,
      @output : IO,
      @subscriber : Watch::Any? = nil,
      @checkpoints : Checkpoint::Schedule? = nil,
    )
      @lock = Sync::Mutex.new
      @stopping = false
      @sent = nil.as(Core::Entry?)
      @sequence = 0_u32
    end

    READ_AHEAD = 1

    def run : Nil
      announce
      requests = receive_ahead

      while (request = requests.receive?)
        break unless serve(request)
      end
    ensure
      @stopping = true
      @checkpoints.try(&.save)
    end

    private def receive_ahead : Channel(Wire::Message)
      requests = Channel(Wire::Message).new(READ_AHEAD)

      spawn do
        begin
          loop { requests.send(Wire.read_message(@input)) }
        rescue Wire::Truncated | IO::Error | Channel::ClosedError
          requests.close
        end
      end

      requests
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
        current = @endpoint.scan(Time.utc.to_unix_ns.to_i64).root
        @sequence += 1

        if @sent.nil?
          Wire::TreeUpdate.new(@sequence, current).write(@output)
        else
          Wire::TreeDelta.new(@sequence, Core::Differ.diff(@sent, current)).write(@output)
        end

        @sent = current
      end
    rescue IO::Error
      nil
    end

    private def drain : Nil
      subscriber = @subscriber
      return if subscriber.nil?

      @endpoint.mark_dirty(subscriber.drain)
    end

    private def serve(request : Wire::Message) : Bool
      case request
      in Wire::ScanRequest
        @lock.synchronize do
          drain
          current = @endpoint.scan(request.now_ns).root
          @sent = current
          Wire::ScanResponse.new(current).write(@output)
        end
      in Wire::ContentsRequest
        @lock.synchronize do
          Wire::ContentsResponse.new(@endpoint.content_source(request.digests, request.budget)).write(@output)
        end
      in Wire::WriteRequest
        @lock.synchronize do
          outcomes = @endpoint.write(request.changes, Wire::ContentSource::Materialised.new(request.contents))
          @sent = Core::Applier.apply(@sent, Write::Outcome.changes(outcomes)) unless @sent.nil?
          Wire::WriteResponse.new(outcomes).write(@output)
          @checkpoints.try(&.save_if_due)
        end
      in Wire::PollRequest
        @lock.synchronize do
          Wire::PollResponse.new(@subscriber.try(&.pending?) != false).write(@output)
        end
      in Wire::Failure, Wire::ScanResponse, Wire::PollResponse, Wire::TreeUpdate, Wire::TreeDelta,
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
