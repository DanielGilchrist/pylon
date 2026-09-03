require "kebab"
require "../brand"
require "../scan/ignores"
require "../session/local_endpoint"
require "../session/checkpoint/schedule"
require "../session/process_transport"
require "../session/remote_endpoint"
require "../session/runner"
require "../session/session"
require "../session/ssh"
require "../watch/watcher"
require "./brand_converter"
require "./reporter"
require "./target"

struct Pylon::CLI
  @[Kebab::Command(summary: "Sync a local directory with one on a remote host")]
  struct Sync
    include Kebab::Parseable

    DEFAULT_REMOTE_COMMAND = "pylon serve"
    DEFAULT_COMPRESSION    = 9

    @[Kebab::Argument(description: "Local directory")]
    getter local : String

    @[Kebab::Argument(description: "Remote target as user@host:/path")]
    getter remote : String

    @[Kebab::Option(description: "Path to ignore, repeatable")]
    getter ignore : Array(String) = Array(String).new

    @[Kebab::Option(description: "SSH config file")]
    getter config : String?

    @[Kebab::Option(description: "SSH port")]
    getter port : String?

    @[Kebab::Option(description: "Command that starts the remote server")]
    getter remote_command : String = DEFAULT_REMOTE_COMMAND

    @[Kebab::Option(description: "Where to keep sync state")]
    getter state : String?

    @[Kebab::Option(description: "zstd level for content sent over the link, both directions")]
    getter compression : Int32 = DEFAULT_COMPRESSION

    @[Kebab::Option(description: "Conflicts matching this glob keep this machine's copy, repeatable, . is the fallback")]
    getter prefer_local : Array(String) = Array(String).new

    @[Kebab::Option(description: "Conflicts matching this glob keep the remote's copy, repeatable, . is the fallback")]
    getter prefer_remote : Array(String) = Array(String).new

    @[Kebab::Option(short: 'w', description: "Keep running and sync on every change")]
    getter? watch : Bool = false

    @[Kebab::Option(short: 'n', description: "Show what would happen and change nothing")]
    getter? dry_run : Bool = false

    @[Kebab::Option(short: 'v', description: "Explain every skipped path")]
    getter? verbose : Bool = false

    @[Kebab::Option(converter: BrandConverter, description: "Name to show in output instead of pylon")]
    getter brand : Brand = Brand::DEFAULT

    def run : Nil
      reporter = Reporter.new(STDOUT, verbose?, dry_run?, brand: brand)
      target = Target.parse(remote)

      if target.is_a?(Target::Invalid)
        fail_with(reporter, target.message)
      end

      preferences = Core::Preferences.build(prefer_local, prefer_remote)

      if preferences.is_a?(Core::Preferences::Invalid)
        fail_with(reporter, preferences.message)
      end

      ignores = Scan::Ignores.new(ignore)
      restored = restore(reporter)

      transport = Session::ProcessTransport.open(
        "ssh",
        Session::SSH.command(
          host: target.host,
          remote_command: server_command(target.path),
          config: config,
          port: port,
        ),
      ) { |line| reporter.relay(line) }

      if transport.is_a?(Problem)
        fail_with(reporter, transport.reason)
      end

      begin
        left = Session::LocalEndpoint.new(local, ignores, compression: compression)
        left.cache = restored.local_cache
        left.on_stream = ->(bytes : UInt64) : Nil { reporter.streamed(bytes) }

        reporter.observe(left.tally)
        reporter.starting(local, remote) unless dry_run?

        signals = Channel(Nil).new(16)
        remote_endpoint = Session::RemoteEndpoint.new(transport.reader, transport.writer, signals, brand: brand)
        session = Session::Session.new(
          left,
          remote_endpoint,
          preferences: preferences,
          base: restored.base,
          dry_run: dry_run?,
          push_first: restored.base.nil?,
          on_progress: ->(update : Session::Progress) : Nil { reporter.progress(update) },
        )

        checkpoints = state.try do |path|
          Session::Checkpoint::Schedule.new(
            path,
            -> : Session::Checkpoint { Session::Checkpoint.new(session.base, left.cache, restored.remote_cache) },
            on_problem: ->(problem : String) : Nil { reporter.warn(problem) },
          )
        end

        drive(session, reporter, checkpoints, remote_endpoint, left, target, signals)
      ensure
        transport.close
      end
    end

    private def drive(
      session : Session::Session(Session::LocalEndpoint, Session::RemoteEndpoint),
      reporter : Reporter,
      checkpoints : Session::Checkpoint::Schedule?,
      remote_endpoint : Session::RemoteEndpoint,
      local_endpoint : Session::LocalEndpoint,
      target : Target,
      signals : Channel(Nil),
    ) : Nil
      unless watch?
        cycle_started = Time.instant
        result = session.cycle(Time.utc.to_unix_ns.to_i64)
        report_fault(reporter, result, target) if result.is_a?(Session::Fault)

        reporter.report(result, Time.instant - cycle_started)
        checkpoints.try(&.save)
        return
      end

      subscriber = Watch::Watcher.open(local, ignore, signals, brand)

      if subscriber.is_a?(Watch::Unavailable)
        fail_with(reporter, "watching is unavailable for #{local}: #{subscriber.reason}")
      end

      local_endpoint.accelerate!

      runner = Session::Runner.new(
        session,
        signals,
        before: -> : Nil { local_endpoint.mark_dirty(subscriber.drain) },
        gauge: -> : Int32 { local_endpoint.register(subscriber.drain) },
      )

      Process.on_terminate { runner.stop }

      started = Time.instant
      first = true

      fault = runner.run do |report, elapsed|
        reporter.report(report, first ? nil : elapsed)

        if first
          first = false
          reporter.ready(Time.instant - started, local_endpoint.cache.size)
        end

        checkpoints.try(&.save_if_due)
      end

      report_fault(reporter, fault, target) if fault

      checkpoints.try(&.save)
      subscriber.close
    end

    private def report_fault(reporter : Reporter, fault : Session::Fault, target : Target) : NoReturn
      case fault
      in Session::Stopped
        fail_with(reporter, "#{fault.explain}. Check that #{remote_command.inspect} exists on #{target.host}")
      in Session::Incompatible, Session::Misbehaved
        fail_with(reporter, fault.explain)
      end
    end

    private def restore(reporter : Reporter) : Session::Checkpoint
      path = state
      return Session::Checkpoint.new if path.nil?

      case (loaded = Session::Checkpoint.load(path))
      in Session::Checkpoint then loaded
      in Session::Checkpoint::Absent
        Session::Checkpoint.new
      in Session::Checkpoint::Damaged
        reporter.warn("ignoring the sync state at #{path} (#{loaded.reason}), scanning from scratch")
        Session::Checkpoint.new
      end
    end

    private def fail_with(reporter : Reporter, message : String) : NoReturn
      reporter.failed(message)
      exit(1)
    end

    private def server_command(remote_path : String) : String
      parts = [remote_command, Process.quote(remote_path)]
      parts << "--compression" << compression.to_s
      ignore.each { |pattern| parts << "--ignore" << Process.quote(pattern) }
      parts << "--brand" << Process.quote(brand.name)
      parts.join(' ')
    end
  end
end
