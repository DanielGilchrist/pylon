require "kebab"
require "../session/server"
require "../session/local_endpoint"
require "../session/process_transport"
require "../session/remote_endpoint"
require "../session/session"
require "../session/ssh"
require "../session/store"
require "./reporter"
require "./target"

module Pylon::CLI
  DEFAULT_REMOTE_COMMAND = "pylon server"

  @[Kebab::Command(summary: "Serve a directory to a pylon client over stdin and stdout")]
  struct Server
    include Kebab::Parseable

    @[Kebab::Argument(description: "Directory to serve")]
    getter root : String

    @[Kebab::Option(description: "Path to ignore, repeatable")]
    getter ignore : Array(String) = [] of String

    def run : Nil
      endpoint = Session::LocalEndpoint.new(root, Scan::Ignores.new(ignore))

      IO::FileDescriptor.set_blocking(STDIN.fd, false)
      IO::FileDescriptor.set_blocking(STDOUT.fd, false)

      Session::Server.new(endpoint, STDIN, STDOUT).run
    end
  end

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
      report = session.cycle(Time.utc.to_unix_ns.to_i64)

      Reporter.new(STDOUT, verbose?).report(report)

      state.try do |path|
        Session::Store.save(path, Session::State.new(session.base, left.cache, right.cache))
      end
    end
  end

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

        session = Session::Session.new(
          left,
          Session::RemoteEndpoint.new(transport.reader, transport.writer),
          base: restored.base,
        )

        report =
          begin
            session.cycle(Time.utc.to_unix_ns.to_i64)
          rescue Wire::Truncated
            abort_with("the remote server did not start; check that #{remote_command.inspect} exists on #{target.host}")
          rescue error : Session::RemoteEndpoint::ProtocolError
            abort_with("the remote server misbehaved: #{error.message}")
          end

        Reporter.new(STDOUT, verbose?).report(report)

        state.try do |path|
          Session::Store.save(path, Session::State.new(session.base, left.cache, restored.remote_cache))
        end
      ensure
        transport.close
      end
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

  @[Kebab::Command(name: "pylon", summary: "Two way file sync between a laptop and a dev box")]
  struct Root
    include Kebab::Parseable

    @[Kebab::Subcommand]
    getter command : Serve | Local | Sync
  end
end
