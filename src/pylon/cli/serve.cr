require "kebab"
require "../scan/ignores"
require "../session/server"
require "../session/local_endpoint"
require "../session/checkpoint/schedule"
require "../watch/watcher"

struct Pylon::CLI
  @[Kebab::Command(summary: "Serve a directory to a pylon client over stdin and stdout")]
  struct Serve
    include Kebab::Parseable

    @[Kebab::Argument(description: "Directory to serve")]
    getter root : String

    @[Kebab::Option(description: "Path to ignore, repeatable")]
    getter ignore : Array(String) = [] of String

    @[Kebab::Option(description: "Where to keep sync state")]
    getter state : String?

    def run : Nil
      endpoint = Session::LocalEndpoint.new(root, Scan::Ignores.new(ignore))

      state.try do |path|
        restored = Session::Checkpoint.load(path)
        endpoint.cache = restored.local_cache if restored
      end

      subscriber = Watch::Watcher.open(root, ignore, Channel(Nil).new(1), "pylon-server")
      endpoint.accelerate! if subscriber

      checkpoints = state.try do |path|
        Session::Checkpoint::Schedule.new(path, -> { Session::Checkpoint.new(nil, endpoint.cache) })
      end

      IO::FileDescriptor.set_blocking(STDIN.fd, false)
      IO::FileDescriptor.set_blocking(STDOUT.fd, false)

      Session::Server.new(endpoint, STDIN, STDOUT, subscriber, checkpoints).run

      subscriber.try(&.close)
    end
  end

  @[Kebab::Command(summary: "Sync two directories on this machine")]
end
