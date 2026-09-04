require "sync"
require "../brand"
require "../fibers"
require "../problem"
require "../scan/ignores"
require "../watch/watcher"
require "../core/applier"
require "../core/differ"
require "../wire/message"
require "./local_endpoint"
require "./checkpoint/schedule"

module Pylon::Session
  class Server
    READ_AHEAD        = 1
    PROGRESS_INTERVAL = 250.milliseconds

    def self.accept(input : IO, output : IO, log : IO) : Server | Problem
      if (problem = Wire::Greeting.write(output))
        return Problem.new("the greeting could not be sent: #{problem.reason}")
      end

      case (message = Wire::Message.read(input))
      in Wire::Closed
        Problem.new("the client went away before configuring this side")
      in Wire::Invalid
        Problem.new("the configuration could not be read: #{message.reason}")
      in Wire::Message::Configure
        configured(message, input, output, log)
      in Wire::Message::Failure,
         Wire::Message::ScanRequest,
         Wire::Message::ScanResponse,
         Wire::Message::ContentsRequest,
         Wire::Message::ContentsResponse,
         Wire::Message::SignaturesRequest,
         Wire::Message::SignaturesResponse,
         Wire::Message::WriteRequest,
         Wire::Message::WriteResponse,
         Wire::Message::TreeUpdate,
         Wire::Message::TreeDelta,
         Wire::Message::ScanProgress,
         Wire::Message::TreeAnnounce
        refusal = "the first message must configure this side, not a #{message.class.name}"
        Wire::Message.write(output, Wire::Message::Failure.new(refusal))
        Problem.new(refusal)
      end
    end

    private def self.configured(configure : Wire::Message::Configure, input : IO, output : IO, log : IO) : Server
      brand = configure.brand
      endpoint = LocalEndpoint.new(configure.root, Scan::Ignores.new(configure.ignores), compression: configure.compression)

      if (state = configure.state)
        case (restored = Checkpoint.load(state))
        in Checkpoint then endpoint.cache = restored.local_cache
        in Checkpoint::Absent
        in Checkpoint::Damaged
          log.puts(brand.prefix("ignoring the sync state at #{state} (#{restored.reason}), scanning from scratch"))
        end
      end

      subscriber = nil

      if configure.watch?
        case (opened = Watch::Watcher.open(configure.root, configure.ignores, Channel(Nil).new(1), brand))
        in Watch::Any
          subscriber = opened
          endpoint.accelerate!
        in Watch::Unavailable
          log.puts(brand.prefix("watching is unavailable on this side (#{opened.reason}), every cycle will rescan"))
        end
      end

      checkpoints = configure.state.try do |path|
        Checkpoint::Schedule.new(
          path,
          -> : Checkpoint { Checkpoint.new(nil, endpoint.cache) },
          on_problem: ->(problem : String) : Nil { log.puts(brand.prefix(problem)) },
        )
      end

      new(endpoint, input, output, subscriber, checkpoints, log, brand: brand, watch: configure.watch?)
    end

    @sent : Core::Entry? = nil
    @pushed : Channel(Nil)? = nil

    private def initialize(
      @endpoint : LocalEndpoint,
      @input : IO,
      @output : IO,
      @subscriber : Watch::Any?,
      @checkpoints : Checkpoint::Schedule?,
      @log : IO,
      *,
      @brand : Brand,
      @watch : Bool,
    ) : Nil
      @lock = Sync::Mutex.new
      @stopping = false
      @sequence = 0_u32
    end

    def run : Nil
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
      @subscriber.try(&.close)
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
      return unless @watch

      push

      subscriber = @subscriber
      return if subscriber.nil?

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
        {% if flag?(:timing) %}
          started = Time.instant
        {% end %}

        drain
        current = scan_reporting(Time.utc.to_unix_ns.to_i64)
        @sequence += 1

        {% if flag?(:timing) %}
          scanned = Time.instant
        {% end %}

        failed =
          if @sent.nil?
            announce(current) || Wire::Message.write(@output, Wire::Message::TreeUpdate.new(@sequence, current, live: !@subscriber.nil?))
          else
            Wire::Message.write(@output, Wire::Message::TreeDelta.new(@sequence, Core::Differ.diff(@sent, current)))
          end

        {% if flag?(:timing) %}
          STDERR.puts("server push: scan=%.1fms send=%.1fms files=%d" % [
            (scanned - started).total_milliseconds,
            (Time.instant - scanned).total_milliseconds,
            @endpoint.cache.size,
          ])
        {% end %}

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

    private def scan_reporting(now_ns : Int64) : Core::Entry?
      scanned = Channel(Core::Entry?).new(1)
      Fibers.isolated(:server_scan) { scanned.send(@endpoint.scan(now_ns)) }
      reporting = true

      loop do
        select
        when current = scanned.receive
          return current
        when timeout(PROGRESS_INTERVAL)
          next unless reporting

          tally = @endpoint.tally
          reporting = Wire::Message.write(@output, Wire::Message::ScanProgress.new(tally.files, tally.hashed_bytes)).nil?
        end
      end
    end

    private def announce(current : Core::Entry?) : Problem?
      Wire::Message.write(@output, Wire::Message::TreeAnnounce.new(Wire::Chunks.measure_entry(current)))
    end

    private def serve(request : Wire::Message::Any) : Bool
      problem =
        case request
        in Wire::Message::ScanRequest
          @lock.synchronize do
            drain
            current = scan_reporting(request.now_ns)
            @sent = current
            announce(current) || Wire::Message.write(@output, Wire::Message::ScanResponse.new(current))
          end
        in Wire::Message::ContentsRequest
          @lock.synchronize do
            source = @endpoint.content_source(request.digests, request.budget, request.signatures, Wire::Prefixed::Bases.new)
            response = Wire::Message::ContentsResponse.new(source)
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
           Wire::Message::WriteResponse,
           Wire::Message::Configure,
           Wire::Message::ScanProgress,
           Wire::Message::TreeAnnounce
          @lock.synchronize do
            failure = Wire::Message::Failure.new("the client sent a #{request.class.name} where a request was expected")
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
