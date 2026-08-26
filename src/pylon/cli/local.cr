require "kebab"
require "../scan/ignores"
require "../session/local_endpoint"
require "../session/persister"
require "../session/runner"
require "../session/session"
require "../session/store"
require "../watch/subscriber"
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

    @[Kebab::Option(short: 'w', description: "Keep running and sync on every change")]
    getter? watch : Bool = false

    @[Kebab::Option(short: 'v', description: "Explain every skipped path")]
    getter? verbose : Bool = false

    def run : Nil
      ignores = Scan::Ignores.new(ignore)
      restored = state.try { |path| Session::Store.load(path) } || Session::State.new

      left = Session::LocalEndpoint.new(local, ignores)
      right = Session::LocalEndpoint.new(remote, ignores)
      left.cache = restored.local_cache
      right.cache = restored.remote_cache

      session = Session::Session.new(left, right, base: restored.base)
      reporter = Reporter.new(STDOUT, verbose?)
      persister = state.try do |path|
        Session::Persister.new(path, -> { Session::State.new(session.base, left.cache, right.cache) })
      end

      unless watch?
        reporter.report(session.cycle(Time.utc.to_unix_ns.to_i64))
        persister.try(&.flush)
        return
      end

      signals = Channel(Nil).new(16)
      watchers = [{left, local}, {right, remote}].compact_map do |endpoint, root|
        subscriber = Watch::Subscriber.open(root, ignore, signals)
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
        persister.try(&.maybe)
      end

      persister.try(&.flush)
      watchers.each { |_, subscriber| subscriber.close }
    end

    private def drain(watchers) : Nil
      watchers.each do |endpoint, subscriber|
        changes = subscriber.drain

        if changes.fresh
          endpoint.invalidate
        else
          endpoint.mark_dirty(changes.paths)
        end
      end
    end
  end

  @[Kebab::Command(summary: "Sync a local directory with one on a remote host")]
end
