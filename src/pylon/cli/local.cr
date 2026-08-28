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

    @[Kebab::Option(short: 'w', description: "Keep running and sync on every change")]
    getter? watch : Bool = false

    @[Kebab::Option(short: 'n', description: "Show what would happen and change nothing")]
    getter? dry_run : Bool = false

    @[Kebab::Option(short: 'v', description: "Explain every skipped path")]
    getter? verbose : Bool = false

    def run : Nil
      ignores = Scan::Ignores.new(ignore)
      restored = state.try { |path| Session::Checkpoint.load(path) } || Session::Checkpoint.new

      left = Session::LocalEndpoint.new(local, ignores, compression: compression)
      right = Session::LocalEndpoint.new(remote, ignores, compression: compression)
      left.cache = restored.local_cache
      right.cache = restored.remote_cache

      session = Session::Session.new(
        left,
        right,
        base: restored.base,
        dry_run: dry_run?,
        push_first: restored.base.nil?,
      )
      reporter = Reporter.new(STDOUT, verbose?, dry_run?)
      checkpoints = state.try do |path|
        Session::Checkpoint::Schedule.new(path, -> { Session::Checkpoint.new(session.base, left.cache, right.cache) })
      end

      unless watch?
        reporter.report(session.cycle(Time.utc.to_unix_ns.to_i64))
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
        STDERR.puts("pylon: watching needs watchman on this machine")
        exit(1)
      end

      watchers.each { |endpoint, _| endpoint.accelerate! }

      runner = Session::Runner.new(session, signals, before: -> { drain(watchers) })
      Signal::INT.trap { runner.stop }

      runner.run do |report|
        reporter.report(report)
        checkpoints.try(&.save_if_due)
      end

      checkpoints.try(&.save)
      watchers.each { |_, subscriber| subscriber.close }
    end

    private def drain(watchers) : Nil
      watchers.each { |endpoint, subscriber| endpoint.mark_dirty(subscriber.drain) }
    end
  end
end
