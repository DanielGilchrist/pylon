require "kebab"
require "../scan/ignores"
require "../session/local_endpoint"
require "../session/checkpoint/schedule"
require "../session/runner"
require "../session/session"
require "../watch/watcher"
require "./reporter"

struct Pylon::CLI
  @[Kebab::Command(summary: "Sync two directories on this machine")]
  struct Local
    include Kebab::Parseable

    @[Kebab::Argument(description: "First directory")]
    getter local : String

    @[Kebab::Argument(description: "Second directory")]
    getter remote : String

    @[Kebab::Option(description: "Path to ignore, repeatable")]
    getter ignore : Array(String) = [] of String

    @[Kebab::Option(description: "Where to keep sync state")]
    getter state : String?

    @[Kebab::Option(description: "zstd level for content sent from this side")]
    getter compression : Int32 = Pylon::Compress::Zstd::DEFAULT_LEVEL

    @[Kebab::Option(description: "Conflicts matching this glob keep the first directory's copy, repeatable, . is the fallback")]
    getter prefer_local : Array(String) = [] of String

    @[Kebab::Option(description: "Conflicts matching this glob keep the second directory's copy, repeatable, . is the fallback")]
    getter prefer_remote : Array(String) = [] of String

    @[Kebab::Option(short: 'w', description: "Keep running and sync on every change")]
    getter? watch : Bool = false

    @[Kebab::Option(short: 'n', description: "Show what would happen and change nothing")]
    getter? dry_run : Bool = false

    @[Kebab::Option(short: 'v', description: "Explain every skipped path")]
    getter? verbose : Bool = false

    def run : Nil
      preferences = Core::Preferences.build(prefer_local, prefer_remote)

      if preferences.is_a?(Core::Preferences::Invalid)
        STDERR.puts("pylon: #{preferences.message}")
        exit(1)
      end

      ignores = Scan::Ignores.new(ignore)
      reporter = Reporter.new(STDOUT, verbose?, dry_run?)
      restored = restore(reporter)

      left = Session::LocalEndpoint.new(local, ignores, compression: compression)
      right = Session::LocalEndpoint.new(remote, ignores, compression: compression)
      left.cache = restored.local_cache
      right.cache = restored.remote_cache

      session = Session::Session.new(
        left,
        right,
        preferences: preferences,
        base: restored.base,
        dry_run: dry_run?,
        push_first: restored.base.nil?,
      )
      checkpoints = state.try do |path|
        Session::Checkpoint::Schedule.new(
          path,
          -> { Session::Checkpoint.new(session.base, left.cache, right.cache) },
          on_problem: ->(problem : String) { reporter.warn(problem) },
        )
      end

      unless watch?
        result = session.cycle(Time.utc.to_unix_ns.to_i64)

        if result.is_a?(Session::Fault)
          reporter.failed(result.explain)
          exit(1)
        end

        reporter.report(result)
        checkpoints.try(&.save)
        return
      end

      signals = Channel(Nil).new(16)
      watchers = [{left, local}, {right, remote}].compact_map do |endpoint, root|
        subscriber = Watch::Watcher.open(root, ignore, signals)
        subscriber.nil? ? nil : {endpoint, subscriber}
      end

      if watchers.size < 2
        watchers.each { |_, subscriber| subscriber.close }
        reporter.failed("watching is unavailable for this directory")
        exit(1)
      end

      watchers.each { |endpoint, _| endpoint.accelerate! }

      runner = Session::Runner.new(session, signals, before: -> { drain(watchers) })
      Signal::INT.trap { runner.stop }

      fault = runner.run do |report|
        reporter.report(report)
        checkpoints.try(&.save_if_due)
      end

      if fault
        reporter.failed(fault.explain)
        exit(1)
      end

      checkpoints.try(&.save)
      watchers.each { |_, subscriber| subscriber.close }
    end

    private def restore(reporter : Reporter) : Session::Checkpoint
      path = state
      return Session::Checkpoint.new if path.nil?

      case loaded = Session::Checkpoint.load(path)
      in Session::Checkpoint then loaded
      in Session::Checkpoint::Absent
        Session::Checkpoint.new
      in Session::Checkpoint::Damaged
        reporter.warn("ignoring the sync state at #{path} (#{loaded.reason}), scanning from scratch")
        Session::Checkpoint.new
      end
    end

    private def drain(watchers) : Nil
      watchers.each { |endpoint, subscriber| endpoint.mark_dirty(subscriber.drain) }
    end
  end
end
