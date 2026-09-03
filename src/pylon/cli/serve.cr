require "kebab"
require "../brand"
require "../scan/ignores"
require "../session/server"
require "../session/local_endpoint"
require "../session/checkpoint/schedule"
require "../watch/watcher"
require "./brand_converter"

struct Pylon::CLI
  @[Kebab::Command(summary: "Serve a directory to a pylon client over stdin and stdout")]
  struct Serve
    include Kebab::Parseable

    @[Kebab::Argument(description: "Directory to serve")]
    getter root : String

    @[Kebab::Option(description: "Path to ignore, repeatable")]
    getter ignore : Array(String) = Array(String).new

    @[Kebab::Option(description: "Where to keep sync state")]
    getter state : String?

    @[Kebab::Option(description: "zstd level for content sent from this side")]
    getter compression : Int32 = Pylon::Compress::Zstd::DEFAULT_LEVEL

    @[Kebab::Option(converter: BrandConverter, description: "Name to show in output instead of pylon")]
    getter brand : Brand = Brand::DEFAULT

    def run : Nil
      endpoint = Session::LocalEndpoint.new(root, Scan::Ignores.new(ignore), compression: compression)

      state.try do |path|
        case (restored = Session::Checkpoint.load(path))
        in Session::Checkpoint then endpoint.cache = restored.local_cache
        in Session::Checkpoint::Absent
        in Session::Checkpoint::Damaged
          STDERR.puts(brand.prefix("ignoring the sync state at #{path} (#{restored.reason}), scanning from scratch"))
        end
      end

      case (opened = Watch::Watcher.open(root, ignore, Channel(Nil).new(1), brand))
      in Watch::Any
        subscriber = opened
        endpoint.accelerate!
      in Watch::Unavailable
        subscriber = nil
        STDERR.puts(brand.prefix("watching is unavailable on this side (#{opened.reason}), every cycle will rescan"))
      end

      checkpoints = state.try do |path|
        Session::Checkpoint::Schedule.new(
          path,
          -> : Session::Checkpoint { Session::Checkpoint.new(nil, endpoint.cache) },
          on_problem: ->(problem : String) : Nil { STDERR.puts(brand.prefix(problem)) },
        )
      end

      IO::FileDescriptor.set_blocking(STDIN.fd, false)
      IO::FileDescriptor.set_blocking(STDOUT.fd, false)

      Session::Server.new(endpoint, STDIN, STDOUT, subscriber, checkpoints, brand: brand).run

      subscriber.try(&.close)
    end
  end
end
