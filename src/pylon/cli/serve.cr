require "kebab"
require "../scan/ignores"
require "../session/server"
require "../session/local_endpoint"
require "../session/persister"
require "../session/store"
require "../watch/subscriber"

module Pylon::CLI
  @[Kebab::Command(summary: "Serve a directory to a pylon client over stdin and stdout")]
  struct Server
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
        restored = Session::Store.load(path)
        endpoint.cache = restored.local_cache if restored
      end

      subscriber = Watch::Subscriber.open(root, ignore, name: "pylon-server")
      endpoint.accelerate! if subscriber

      persister = state.try do |path|
        Session::Persister.new(path, -> { Session::State.new(nil, endpoint.cache) })
      end

      IO::FileDescriptor.set_blocking(STDIN.fd, false)
      IO::FileDescriptor.set_blocking(STDOUT.fd, false)

      Session::Server.new(endpoint, STDIN, STDOUT, subscriber, persister).run

      subscriber.try(&.close)
    end
  end

  @[Kebab::Command(summary: "Sync two directories on this machine")]
end
