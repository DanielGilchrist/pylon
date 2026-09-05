require "kebab"
require "../brand"
require "../scan/ignores"
require "../session/local_endpoint"
require "../session/checkpoint/schedule"
require "../session/content_store"
require "../session/process_transport"
require "../session/remote_endpoint"
require "../session/runner"
require "../session/session"
require "../session/ssh"
require "../watch/dirty_paths"
require "../watch/watcher"
require "../wire/message"
require "./brand_converter"
require "./reporter"
require "./target"

struct Pylon::CLI
  @[Kebab::Command(summary: "Sync a local directory with one on a remote host")]
  struct Sync
    include Kebab::Parseable

    DEFAULT_REMOTE_BINARY = "pylon"
    DEFAULT_COMPRESSION   = 9

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

    @[Kebab::Option(description: "Path of the binary on the remote host")]
    getter remote_binary : String = DEFAULT_REMOTE_BINARY

    @[Kebab::Option(description: "Where to keep sync state")]
    getter state : String?

    @[Kebab::Option(description: "Where the remote host keeps its sync state")]
    getter remote_state : String?

    @[Kebab::Option(description: "zstd level for content sent over the link, both directions")]
    getter compression : Int32 = DEFAULT_COMPRESSION

    @[Kebab::Option(
      description: "Conflicts matching this glob keep this machine's copy, repeatable, . is the " \
                   "fallback",
    )]
    getter prefer_local : Array(String) = Array(String).new

    @[Kebab::Option(
      description: "Conflicts matching this glob keep the remote's copy, repeatable, . is the " \
                   "fallback",
    )]
    getter prefer_remote : Array(String) = Array(String).new

    @[Kebab::Option(short: 'w', description: "Keep running and sync on every change")]
    getter? watch : Bool = false

    @[Kebab::Option(short: 'n', description: "Show what would happen and change nothing")]
    getter? dry_run : Bool = false

    @[Kebab::Option(short: 'v', description: "Explain every skipped path")]
    getter? verbose : Bool = false

    @[Kebab::Option(
      converter: BrandConverter,
      description: "Name to show in output instead of pylon",
    )]
    getter brand : Brand = Brand::DEFAULT

    def run : Nil
      reporter = Reporter.new(STDOUT, verbose?, dry_run?, brand: brand)
      target = Target.parse(remote)

      if target.is_a?(Problem)
        fail_with(reporter, target.reason)
      end

      preferences = Core::Preferences.build(prefer_local, prefer_remote)

      if preferences.is_a?(Problem)
        fail_with(reporter, preferences.reason)
      end

      ignores = Scan::Ignores.new(ignore)
      restored = restore(reporter)

      transport = Session::ProcessTransport.open(
        "ssh",
        Session::SSH.command(
          host: target.host,
          remote_command: "#{remote_binary} remote",
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
        left.kept = open_store(reporter)

        reporter.observe(left.scanned, left.sent)
        reporter.starting(local, remote) unless dry_run?

        dirty_paths = Watch::DirtyPaths.new(Channel(Nil).new(16))
        remote_endpoint = Session::RemoteEndpoint.new(
          transport.reader,
          transport.writer,
          configuration(target.path, restored.shared_tree),
          dirty_paths.signals,
          resume: restored.shared_tree,
        )

        reporter.observe(remote_endpoint.inbound)

        session = Session::Session.new(
          left,
          remote_endpoint,
          preferences: preferences,
          base: restored.base,
          dry_run: dry_run?,
          push_first: true,
          narrator: reporter,
        )

        checkpoints = state.try { |path| Session::Checkpoint::Schedule.new(path) }

        drive(session, reporter, checkpoints, remote_endpoint, target, dirty_paths)
      ensure
        transport.close
      end
    end

    private def drive(
      session : Session::Session(Session::LocalEndpoint, Session::RemoteEndpoint, Reporter),
      reporter : Reporter,
      checkpoints : Session::Checkpoint::Schedule?,
      remote_endpoint : Session::RemoteEndpoint,
      target : Target,
      dirty_paths : Watch::DirtyPaths,
    ) : Nil
      unless watch?
        cycle_started = Time.instant
        result = session.cycle(Time.utc.to_unix_ns.to_i64)
        report_fault(reporter, result, target) if result.is_a?(Session::Fault)

        reporter.report(result, Time.instant - cycle_started)
        checkpoint(checkpoints, session, remote_endpoint, reporter) do |schedule, saved|
          schedule.save(saved)
        end

        return
      end

      subscriber = Watch::Watcher.open(local, ignore, dirty_paths, brand)

      if subscriber.is_a?(Problem)
        fail_with(reporter, "watching is unavailable for #{local}: #{subscriber.reason}")
      end
      runner = Session::Runner.new(session, dirty_paths)
      Process.on_terminate { runner.stop }

      started = Time.instant
      first = true

      fault = runner.run do |report, elapsed|
        if first
          first = false
          reporter.report(report, nil)
          reporter.ready(Time.instant - started, session.local.cache.size)
        else
          reporter.report(report, elapsed)
        end

        checkpoint(checkpoints, session, remote_endpoint, reporter) do |schedule, saved|
          schedule.save_if_due(saved)
        end
      end

      report_fault(reporter, fault, target) if fault

      checkpoint(checkpoints, session, remote_endpoint, reporter) do |schedule, saved|
        schedule.save(saved)
      end

      subscriber.close
    end

    private def checkpoint(
      checkpoints : Session::Checkpoint::Schedule?,
      session : Session::Session(Session::LocalEndpoint, Session::RemoteEndpoint, Reporter),
      remote_endpoint : Session::RemoteEndpoint,
      reporter : Reporter,
      & : Session::Checkpoint::Schedule, Session::Checkpoint -> Problem?
    ) : Nil
      return if checkpoints.nil?

      saved = Session::Checkpoint.new(session.base, session.local.cache, remote_endpoint.tree)
      problem = yield checkpoints, saved
      reporter.warn(problem.reason) if problem
    end

    private def report_fault(
      reporter : Reporter,
      fault : Session::Fault,
      target : Target,
    ) : NoReturn
      case fault
      in Session::Stopped
        fail_with(
          reporter,
          "#{fault.explain}. Check that #{remote_binary.inspect} exists on #{target.host}",
        )
      in Session::Incompatible, Session::Misbehaved
        fail_with(reporter, fault.explain)
      end
    end

    private def open_store(reporter : Reporter) : Session::ContentStore?
      path = state
      return if path.nil?

      case (opened = Session::ContentStore.open("#{path}.content", local))
      in Session::ContentStore then opened
      in Problem
        reporter.warn("content will not be kept for reuse or patching: #{opened.reason}")
        nil
      end
    end

    private def restore(reporter : Reporter) : Session::Checkpoint
      path = state
      return Session::Checkpoint.new if path.nil?

      case (loaded = Session::Checkpoint.load(path))
      in Session::Checkpoint then loaded
      in Missing
        Session::Checkpoint.new
      in Problem
        reporter.warn(
          "ignoring the sync state at #{path} (#{loaded.reason}), scanning from scratch",
        )
        Session::Checkpoint.new
      end
    end

    private def fail_with(reporter : Reporter, message : String) : NoReturn
      reporter.failed(message)
      exit(1)
    end

    private def configuration(
      remote_root : String,
      shared_tree : Core::Entry?,
    ) : Wire::Message::Configure
      Wire::Message::Configure.new(
        root: remote_root,
        ignores: ignore,
        compression: compression,
        brand: brand,
        state: remote_state,
        watch: watch?,
        tree_fingerprint: (Core::Digests.fingerprint(shared_tree) if shared_tree),
      )
    end
  end
end
