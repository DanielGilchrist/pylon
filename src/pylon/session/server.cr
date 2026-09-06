require "sync"

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
      in Problem
        Problem.new("the configuration could not be read: #{message.reason}")
      in Wire::Message::Configure
        configured(message, input, output, log)
      in Wire::Message::Failure,
         Wire::Message::ScanRequest,
         Wire::Message::ScanResponse,
         Wire::Message::ContentsRequest,
         Wire::Message::ContentsResponse,
         Wire::Message::ChecksumsRequest,
         Wire::Message::ChecksumsResponse,
         Wire::Message::WriteRequest,
         Wire::Message::WriteResponse,
         Wire::Message::TreeUpdate,
         Wire::Message::TreeChanges,
         Wire::Message::ScanProgress,
         Wire::Message::TreeAnnounce,
         Wire::Message::ReusableRequest,
         Wire::Message::ReusableResponse
        refusal = "the first message must configure this side, not a #{message.class.name}"
        Wire::Message.write(output, Wire::Message::Failure.new(refusal))
        Problem.new(refusal)
      end
    end

    private def self.configured(
      configure : Wire::Message::Configure,
      input : IO,
      output : IO,
      log : IO,
    ) : Server
      brand = configure.brand
      endpoint = LocalEndpoint.new(
        configure.root,
        Scan::Ignores.new(configure.ignores),
        compression: configure.compression,
      )
      shared_tree = nil

      if (state = configure.state)
        case (restored = Checkpoint.load(state))
        in Checkpoint
          endpoint.cache = restored.local_cache
          shared_tree = restored.shared_tree
        in Missing
        in Problem
          log.puts(brand.prefix(
            "ignoring the sync state at #{state} (#{restored.reason}), scanning from scratch",
          ))
        end

        case (store = ContentStore.open("#{state}.content", configure.root))
        in ContentStore
          endpoint.kept = store
        in Problem
          log.puts(brand.prefix("content will not be kept for reuse or patching: #{store.reason}"))
        end
      end

      subscriber = nil

      if configure.watch?
        dirty_paths = Watch::DirtyPaths.new(Channel(Nil).new(1))
        opened = Watch::Watcher.open(configure.root, configure.ignores, dirty_paths, brand)

        case opened
        in Watch::Any
          subscriber = opened
        in Problem
          log.puts(brand.prefix(
            "watching is unavailable on this side (#{opened.reason}), every cycle will rescan",
          ))
        end
      end

      new(
        endpoint,
        input,
        output,
        subscriber,
        log,
        brand: brand,
        state: configure.state,
        tree_fingerprint: configure.tree_fingerprint,
        shared_tree: shared_tree,
      )
    end

    @sent : Core::Entry? = nil
    @pushed : Channel(Nil)? = nil
    @checkpoints : Checkpoint::Schedule? = nil

    private def initialize(
      @endpoint : LocalEndpoint,
      @input : IO,
      @output : IO,
      @subscriber : Watch::Any?,
      @log : IO,
      *,
      @brand : Brand,
      state : String?,
      @tree_fingerprint : Bytes?,
      @shared_tree : Core::Entry?,
    ) : Nil
      @lock = Sync::Mutex.new
      @stopping = false
      @sequence = 0_u32
      @checkpoints = Checkpoint::Schedule.new(state) if state
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
      checkpoint { |schedule, checkpoint| schedule.save(checkpoint) }
      @subscriber.try(&.close)
    end

    private def receive_ahead : Channel(Wire::Message::Any)
      requests = Channel(Wire::Message::Any).new(READ_AHEAD)

      Fibers.detach(:server_requests) do
        loop do
          message = Wire::Message.read(@input)
          break if message.is_a?(Wire::Closed)

          if message.is_a?(Problem)
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
      push

      subscriber = @subscriber
      return if subscriber.nil?

      pushed = Channel(Nil).new
      @pushed = pushed

      Fibers.detach(:server_announce) do
        until @stopping
          subscriber.dirty_paths.signals.receive?
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
      when subscriber.dirty_paths.signals.send(nil)
      else
      end
    end

    private def push : Nil
      problem = @lock.synchronize do
        {% if flag?(:timing) %}
          started = Time.instant
        {% end %}

        apply_dirty_paths
        current = scan_reporting(Time.utc.to_unix_ns.to_i64)
        @sequence += 1

        {% if flag?(:timing) %}
          scanned = Time.instant
        {% end %}

        failed =
          case (sent = @sent)
          in Nil         then open_with(current)
          in Core::Entry then Wire::Message.write(@output, changes_since(sent, current))
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

    private def checkpoint(& : Checkpoint::Schedule, Checkpoint -> Problem?) : Nil
      schedule = @checkpoints
      return if schedule.nil?

      problem = yield schedule, Checkpoint.new(nil, @endpoint.cache, @sent)
      @log.puts(@brand.prefix(problem.reason)) if problem
    end

    private def apply_dirty_paths : Nil
      subscriber = @subscriber
      return if subscriber.nil?

      @endpoint.mark_dirty(subscriber.dirty_paths.consume)
    end

    private def scan_reporting(now_ns : Int64) : Core::Entry?
      result = Channel(Core::Entry?).new(1)
      Fibers.isolated(:server_scan) { result.send(@endpoint.scan(now_ns)) }
      reporting = true

      loop do
        select
        when current = result.receive
          return current
        when timeout(PROGRESS_INTERVAL)
          next unless reporting

          scanned = @endpoint.scanned
          progress = Wire::Message::ScanProgress.new(scanned.files, scanned.bytes)
          reporting = Wire::Message.write(@output, progress).nil?
        end
      end
    end

    private def announce(current : Core::Entry?) : Problem?
      announcement = Wire::Message::TreeAnnounce.new(Wire::Chunks.measure_entry(current))
      Wire::Message.write(@output, announcement)
    end

    private def open_with(current : Core::Entry?) : Problem?
      shared_tree = @shared_tree

      if shared_tree && resumes?(shared_tree)
        return Wire::Message.write(@output, changes_since(shared_tree, current))
      end

      update = Wire::Message::TreeUpdate.new(@sequence, current, live: live?)
      announce(current) || Wire::Message.write(@output, update)
    end

    private def live? : Bool
      !@subscriber.nil?
    end

    private def changes_since(
      sent : Core::Entry,
      current : Core::Entry?,
    ) : Wire::Message::TreeChanges
      Wire::Message::TreeChanges.new(@sequence, Core::Differ.diff(sent, current), live: live?)
    end

    private def resumes?(shared_tree : Core::Entry) : Bool
      fingerprint = @tree_fingerprint
      return false if fingerprint.nil?

      fingerprint == Core::Digests.fingerprint(shared_tree)
    end

    private def serve(request : Wire::Message::Any) : Bool
      problem =
        case request
        in Wire::Message::ScanRequest
          @lock.synchronize do
            apply_dirty_paths
            current = scan_reporting(request.now_ns)
            @sent = current
            response = Wire::Message::ScanResponse.new(current)
            announce(current) || Wire::Message.write(@output, response)
          end
        in Wire::Message::ContentsRequest
          @lock.synchronize do
            source = @endpoint.content_source(
              request.digests,
              request.budget,
              request.checksums,
              Wire::Bases.new,
            )
            response = Wire::Message::ContentsResponse.new(source)
            Wire::Message.write(@output, response)
          end
        in Wire::Message::ChecksumsRequest
          @lock.synchronize do
            response = Wire::Message::ChecksumsResponse.new(@endpoint.checksums(request.bases))
            Wire::Message.write(@output, response)
          end
        in Wire::Message::ReusableRequest
          @lock.synchronize do
            response = Wire::Message::ReusableResponse.new(@endpoint.reusable(request.digests))
            Wire::Message.write(@output, response)
          end
        in Wire::Message::WriteRequest
          @lock.synchronize do
            outcomes = @endpoint.write(
              request.changes,
              Wire::ContentSource::Materialised.new(request.contents),
              request.relocations,
            )
            @sent = Core::Applier.apply(@sent, Write::Outcome.changes(outcomes)) unless @sent.nil?
            failed = Wire::Message.write(@output, Wire::Message::WriteResponse.new(outcomes))
            checkpoint { |schedule, checkpoint| schedule.save_if_due(checkpoint) } if failed.nil?
            failed
          end
        in Wire::Message::Failure,
           Wire::Message::ScanResponse,
           Wire::Message::TreeUpdate,
           Wire::Message::TreeChanges,
           Wire::Message::ContentsResponse,
           Wire::Message::ChecksumsResponse,
           Wire::Message::WriteResponse,
           Wire::Message::Configure,
           Wire::Message::ScanProgress,
           Wire::Message::TreeAnnounce,
           Wire::Message::ReusableResponse
          @lock.synchronize do
            failure = Wire::Message::Failure.new(
              "the client sent a #{request.class.name} where a request was expected",
            )
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
