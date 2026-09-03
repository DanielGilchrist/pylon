require "sync"
require "../brand"
require "../fibers"
require "../watch/watcher"
require "../core/applier"
require "../core/differ"
require "../wire/message"
require "./local_endpoint"
require "./checkpoint/schedule"

module Pylon::Session
  class Server
    @sent : Core::Entry? = nil
    @pushed : Channel(Nil)? = nil

    def initialize(
      @endpoint : LocalEndpoint,
      @input : IO,
      @output : IO,
      @subscriber : Watch::Any? = nil,
      @checkpoints : Checkpoint::Schedule? = nil,
      @log : IO = STDERR,
      *,
      @brand : Brand,
    ) : Nil
      @lock = Sync::Mutex.new
      @stopping = false
      @sequence = 0_u32
    end

    READ_AHEAD = 1

    def run : Nil
      return unless greet

      announce
      requests = receive_ahead

      while (request = requests.receive?)
        break unless serve(request)
      end
    ensure
      @stopping = true
      wake
      @pushed.try(&.receive?)
      @checkpoints.try(&.save)
    end

    private def greet : Bool
      if (problem = Wire::Greeting.write(@output))
        @log.puts(@brand.prefix("the greeting could not be sent, stopping: #{problem.reason}"))
        return false
      end

      true
    end

    private def receive_ahead : Channel(Wire::Message::Any)
      requests = Channel(Wire::Message::Any).new(READ_AHEAD)

      Fibers.detach(:server_requests) do
        loop do
          message = Wire::Message.read(@input)
          break if message.is_a?(Wire::Closed)

          if message.is_a?(Wire::Invalid)
            @log.puts(@brand.prefix("stopped reading requests: #{message.reason}"))
            break
          end

          requests.send(message)
        end
      ensure
        requests.close
      end

      requests
    end

    private def announce : Nil
      subscriber = @subscriber
      return if subscriber.nil?

      push
      pushed = Channel(Nil).new
      @pushed = pushed

      Fibers.detach(:server_announce) do
        until @stopping
          subscriber.signals.receive?
          push unless @stopping
        end
      ensure
        pushed.close
      end
    end

    private def wake : Nil
      subscriber = @subscriber
      return if subscriber.nil?

      select
      when subscriber.signals.send(nil)
      else
      end
    end

    private def push : Nil
      problem = @lock.synchronize do
        drain
        current = @endpoint.scan(Time.utc.to_unix_ns.to_i64)
        @sequence += 1

        failed =
          if @sent.nil?
            Wire::Message.write(@output, Wire::Message::TreeUpdate.new(@sequence, current))
          else
            Wire::Message.write(@output, Wire::Message::TreeDelta.new(@sequence, Core::Differ.diff(@sent, current)))
          end

        @sent = current if failed.nil?
        failed
      end

      @log.puts(@brand.prefix("a tree update could not be sent: #{problem.reason}")) if problem
    end

    private def drain : Nil
      subscriber = @subscriber
      return if subscriber.nil?

      @endpoint.mark_dirty(subscriber.drain)
    end

    private def serve(request : Wire::Message::Any) : Bool
      problem =
        case request
        in Wire::Message::ScanRequest
          @lock.synchronize do
            drain
            current = @endpoint.scan(request.now_ns)
            @sent = current
            Wire::Message.write(@output, Wire::Message::ScanResponse.new(current))
          end
        in Wire::Message::ContentsRequest
          @lock.synchronize do
            response = Wire::Message::ContentsResponse.new(@endpoint.content_source(request.digests, request.budget, request.signatures))
            Wire::Message.write(@output, response)
          end
        in Wire::Message::SignaturesRequest
          @lock.synchronize do
            response = Wire::Message::SignaturesResponse.new(@endpoint.signatures(request.pairs))
            Wire::Message.write(@output, response)
          end
        in Wire::Message::WriteRequest
          @lock.synchronize do
            outcomes = @endpoint.write(request.changes, Wire::ContentSource::Materialised.new(request.contents), request.relocations)
            @sent = Core::Applier.apply(@sent, Write::Outcome.changes(outcomes)) unless @sent.nil?
            failed = Wire::Message.write(@output, Wire::Message::WriteResponse.new(outcomes))
            @checkpoints.try(&.save_if_due) if failed.nil?
            failed
          end
        in Wire::Message::Failure,
           Wire::Message::ScanResponse,
           Wire::Message::TreeUpdate,
           Wire::Message::TreeDelta,
           Wire::Message::ContentsResponse,
           Wire::Message::SignaturesResponse,
           Wire::Message::WriteResponse
          @lock.synchronize do
            failure = Wire::Message::Failure.new("the client sent a #{request.class.name}, which only servers send")
            Wire::Message.write(@output, failure)
          end

          return false
        end

      if problem
        @log.puts(@brand.prefix("a response could not be sent, stopping: #{problem.reason}"))
        return false
      end

      true
    end
  end
end
