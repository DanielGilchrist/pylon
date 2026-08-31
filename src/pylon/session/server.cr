require "sync"
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
    )
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
      if (problem = Wire.write_greeting(@output))
        @log.puts("pylon: the greeting could not be sent, stopping: #{problem.reason}")
        return false
      end

      true
    end

    private def receive_ahead : Channel(Wire::Message)
      requests = Channel(Wire::Message).new(READ_AHEAD)

      spawn do
        begin
          loop do
            message = Wire.read_message(@input)
            break if message.is_a?(Wire::Closed)

            if message.is_a?(Wire::Invalid)
              @log.puts("pylon: stopped reading requests: #{message.reason}")
              break
            end

            requests.send(message)
          end
        ensure
          requests.close
        end
      end

      requests
    end

    private def announce : Nil
      subscriber = @subscriber
      return if subscriber.nil?

      push
      pushed = Channel(Nil).new
      @pushed = pushed

      spawn do
        begin
          until @stopping
            subscriber.signals.receive?
            push unless @stopping
          end
        ensure
          pushed.close
        end
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
        current = @endpoint.scan(Time.utc.to_unix_ns.to_i64).root
        @sequence += 1

        failed =
          if @sent.nil?
            Wire.write_message(@output, Wire::TreeUpdate.new(@sequence, current))
          else
            Wire.write_message(@output, Wire::TreeDelta.new(@sequence, Core::Differ.diff(@sent, current)))
          end

        @sent = current if failed.nil?
        failed
      end

      @log.puts("pylon: a tree update could not be sent: #{problem.reason}") if problem
    end

    private def drain : Nil
      subscriber = @subscriber
      return if subscriber.nil?

      @endpoint.mark_dirty(subscriber.drain)
    end

    private def serve(request : Wire::Message) : Bool
      problem =
        case request
        in Wire::ScanRequest
          @lock.synchronize do
            drain
            current = @endpoint.scan(request.now_ns).root
            @sent = current
            Wire.write_message(@output, Wire::ScanResponse.new(current))
          end
        in Wire::ContentsRequest
          @lock.synchronize do
            Wire.write_message(@output, Wire::ContentsResponse.new(@endpoint.content_source(request.digests, request.budget)))
          end
        in Wire::WriteRequest
          @lock.synchronize do
            outcomes = @endpoint.write(request.changes, Wire::ContentSource::Materialised.new(request.contents))
            @sent = Core::Applier.apply(@sent, Write::Outcome.changes(outcomes)) unless @sent.nil?
            failed = Wire.write_message(@output, Wire::WriteResponse.new(outcomes))
            @checkpoints.try(&.save_if_due) if failed.nil?
            failed
          end
        in Wire::Failure, Wire::ScanResponse, Wire::TreeUpdate, Wire::TreeDelta,
           Wire::ContentsResponse, Wire::WriteResponse
          @lock.synchronize do
            Wire.write_message(@output, Wire::Failure.new("unexpected message from the client"))
          end

          return false
        end

      if problem
        @log.puts("pylon: a response could not be sent, stopping: #{problem.reason}")
        return false
      end

      true
    end
  end
end
