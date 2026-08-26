require "kebab"
require "../scan/ignores"
require "../session/local_endpoint"
require "../session/persister"
require "../session/process_transport"
require "../session/remote_endpoint"
require "../session/runner"
require "../session/session"
require "../session/ssh"
require "../session/store"
require "../watch/subscriber"
require "./reporter"
require "./target"

struct Pylon::CLI
  DEFAULT_REMOTE_COMMAND = "pylon server"

  @[Kebab::Command(summary: "Sync a local directory with one on a remote host")]
  struct Sync
    include Kebab::Parseable

    @[Kebab::Argument(description: "Local directory")]
    getter local : String

    @[Kebab::Argument(description: "Remote target as user@host:/path")]
    getter remote : String

    @[Kebab::Option(description: "Path to ignore, repeatable")]
    getter ignore : Array(String) = [] of String

    @[Kebab::Option(description: "SSH config file")]
    getter config : String?

    @[Kebab::Option(description: "SSH port")]
    getter port : String?

    @[Kebab::Option(description: "Command that starts the remote server")]
    getter remote_command : String = DEFAULT_REMOTE_COMMAND

    @[Kebab::Option(description: "Where to keep sync state")]
    getter state : String?

    @[Kebab::Option(short: 'w', description: "Keep running and sync on every change")]
    getter? watch : Bool = false

    @[Kebab::Option(short: 'v', description: "Explain every skipped path")]
    getter? verbose : Bool = false

    def run : Nil
      target = Target.parse(remote)

      if target.is_a?(Target::Invalid)
        STDERR.puts(target.message)
        exit(1)
      end

      ignores = Scan::Ignores.new(ignore)
      restored = state.try { |path| Session::Store.load(path) } || Session::State.new

      transport = Session::ProcessTransport.open(
        "ssh",
        Session::SSH.command(
          host: target.host,
          remote_command: server_command(target.path),
          config: config,
          port: port,
        ),
      )

      begin
        left = Session::LocalEndpoint.new(local, ignores)
        left.cache = restored.local_cache

        remote_endpoint = Session::RemoteEndpoint.new(transport.reader, transport.writer)
        session = Session::Session.new(left, remote_endpoint, base: restored.base)

        reporter = Reporter.new(STDOUT, verbose?)
        persister = state.try do |path|
          Session::Persister.new(path, -> { Session::State.new(session.base, left.cache, restored.remote_cache) })
        end

        drive(session, reporter, persister, remote_endpoint, left, target)
      ensure
        transport.close
      end
    end

    private def drive(session, reporter, persister, remote_endpoint, local_endpoint, target) : Nil
      run = ->(body : Proc(Nil)) do
        begin
          body.call
        rescue Wire::Truncated
          abort_with("the remote server stopped; check that #{remote_command.inspect} exists on #{target.host}")
        rescue error : Session::RemoteEndpoint::ProtocolError
          abort_with("the remote server misbehaved: #{error.message}")
        end
      end

      unless watch?
        run.call(-> { reporter.report(session.cycle(Time.utc.to_unix_ns.to_i64)); persister.try(&.flush); nil })
        return
      end

      signals = Channel(Nil).new(16)
      subscriber = Watch::Subscriber.open(local, ignore, signals)

      if subscriber.nil?
        STDERR.puts("pylon: watching needs watchman on this machine")
        exit(1)
      end

      local_endpoint.accelerate!

      runner = Session::Runner.new(
        session,
        signals,
        remote_poll: -> { remote_endpoint.changed? },
        before: -> { drain(local_endpoint, subscriber) },
      )

      Signal::INT.trap { runner.stop }

      run.call(-> { runner.run { |report| reporter.report(report); persister.try(&.maybe) }; persister.try(&.flush); nil })
      subscriber.close
    end

    private def drain(endpoint, subscriber) : Nil
      changes = subscriber.drain
      changes.fresh ? endpoint.invalidate : endpoint.mark_dirty(changes.paths)
    end

    private def drain(endpoint, subscriber) : Nil
      changes = subscriber.drain
      changes.fresh ? endpoint.invalidate : endpoint.mark_dirty(changes.paths)
    end

    private def abort_with(message : String) : NoReturn
      STDERR.puts("pylon: #{message}")
      exit(1)
    end

    private def server_command(remote_path : String) : String
      parts = [remote_command, Process.quote(remote_path)]
      ignore.each { |pattern| parts << "--ignore" << Process.quote(pattern) }
      parts.join(' ')
    end
  end
end
