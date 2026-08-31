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

    @[Kebab::Option(description: "zstd level for content sent from this side")]
    getter compression : Int32 = Pylon::Compress::Zstd::DEFAULT_LEVEL

    def run : Nil
      endpoint = Session::LocalEndpoint.new(root, Scan::Ignores.new(ignore), compression: compression)

      state.try do |path|
        case restored = Session::Checkpoint.load(path)
        in Session::Checkpoint then endpoint.cache = restored.local_cache
        in Session::Checkpoint::Absent
        in Session::Checkpoint::Damaged
          STDERR.puts("pylon: ignoring the sync state at #{path} (#{restored.reason}), scanning from scratch")
        end
      end

      case opened = Watch::Watcher.open(root, ignore, Channel(Nil).new(1))
      in Watch::Any
        subscriber = opened
        endpoint.accelerate!
      in Watch::Unavailable
        subscriber = nil
        STDERR.puts("pylon: watching is unavailable on this side (#{opened.reason}), every cycle will rescan")
      end

      checkpoints = state.try do |path|
        Session::Checkpoint::Schedule.new(
          path,
          -> { Session::Checkpoint.new(nil, endpoint.cache) },
          on_problem: ->(problem : String) { STDERR.puts("pylon: #{problem}") },
        )
      end

      IO::FileDescriptor.set_blocking(STDIN.fd, false)
      IO::FileDescriptor.set_blocking(STDOUT.fd, false)

      Session::Server.new(endpoint, STDIN, STDOUT, subscriber, checkpoints).run

      subscriber.try(&.close)
    end
  end
end
