require "file_utils"
require "socket"
require "../../spec_helper"
require "../../../src/pylon/session/server"
require "../../../src/pylon/session/remote_endpoint"
require "../../../src/pylon/session/session"
require "../../../src/pylon/watch/watcher"

include Pylon::Session

private def tick : Int64
  Time.utc.to_unix_ns.to_i64 + Random.rand(1_000_000_i64)
end

# The server only pushes tree deltas when it has a watcher, so this is the only
# topology that exercises the shared delta baseline.
private def in_watched_pair(& : String, String, Session(LocalEndpoint, RemoteEndpoint) ->)
  base = File.join(Dir.tempdir, "pylon-delta-#{Random::Secure.hex(8)}")
  local = File.join(base, "local")
  remote = File.join(base, "remote")
  Dir.mkdir_p(local)
  Dir.mkdir_p(remote)

  signals = ::Channel(Nil).new(16)
  watcher = Pylon::Watch::Watcher.open(remote, [] of String, signals, "pylon-delta-spec")

  if watcher.nil?
    FileUtils.rm_rf(base)
    pending! "no filesystem watcher available"
  end

  endpoint = LocalEndpoint.new(remote)
  endpoint.accelerate!

  client, socket = UNIXSocket.pair
  server = Server.new(endpoint, socket, socket, watcher)
  spawn { server.run }

  begin
    yield local, remote, Session.new(LocalEndpoint.new(local), RemoteEndpoint.new(client, client), push_first: true)
  ensure
    watcher.close
    client.close
    socket.close
    FileUtils.rm_rf(base)
  end
end

describe "the tree delta baseline" do
  it "survives a push larger than a single batch" do
    in_watched_pair do |local, remote, session|
      Dir.mkdir_p(File.join(local, "app", "models"))
      Dir.mkdir_p(File.join(local, "db"))
      400.times { |index| File.write(File.join(local, "app", "models", "f#{index}.rb"), "class F#{index}; end") }
      File.write(File.join(local, "db", "structure.sql"), "-- schema")

      session.cycle(tick)
      sleep 300.milliseconds # let the server's watcher fire and push a delta

      3.times do
        report = session.cycle(tick)
        report.halted?.should be_false, "a cycle halted, which means a side looked emptied"
        sleep 150.milliseconds
      end

      Dir.exists?(File.join(local, "app", "models")).should be_true, "the local tree was deleted"
      Dir.children(File.join(local, "app", "models")).size.should eq(400)
      Dir.children(File.join(remote, "app", "models")).size.should eq(400)
      File.exists?(File.join(local, "db", "structure.sql")).should be_true
    end
  end
end
