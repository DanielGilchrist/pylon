require "file_utils"
require "socket"
require "../../spec_helper"
require "../../../src/pylon/session/server"
require "../../../src/pylon/session/remote_endpoint"
require "../../../src/pylon/session/session"
require "../../support/remote_end"

include Pylon::Session

private def tick : Int64
  Time.utc.to_unix_ns.to_i64 + Random.rand(1_000_000_i64)
end

# The server only pushes tree deltas when it has a watcher, so this is the only
# topology that exercises the shared delta baseline.
private def in_watched_pair(& : String, String, Session(LocalEndpoint, RemoteEndpoint), ::Channel(Nil) ->) : Nil
  base = File.join(Dir.tempdir, "pylon-delta-#{Random::Secure.hex(8)}")
  local = File.join(base, "local")
  remote = File.join(base, "remote")
  Dir.mkdir_p(local)
  Dir.mkdir_p(remote)

  client, socket = UNIXSocket.pair
  serve_remote_end(socket)

  pushes = ::Channel(Nil).new(16)

  begin
    session = build_session(
      local_endpoint(local),
      RemoteEndpoint.new(client, client, remote_configuration(remote, watch: true), pushes, resume: nil),
      push_first: true,
    )
    yield local, remote, session, pushes
  ensure
    client.close
    socket.close
    FileUtils.rm_rf(base)
  end
end

private def await_push(pushes : ::Channel(Nil)) : Nil
  select
  when pushes.receive
  when timeout(5.seconds)
    fail("the server never pushed a tree update")
  end
end

describe "the tree delta baseline" do
  it "stays correct across the client's own writes" do
    in_watched_pair do |local, remote, session, pushes|
      20.times { |index| File.write(File.join(local, "f#{index}.rb"), "body #{index}") }
      cycle!(session, tick)
      await_push(pushes)

      File.write(File.join(local, "mine.rb"), "written by the client")
      cycle!(session, tick)
      await_push(pushes)

      File.write(File.join(remote, "theirs.rb"), "written on the box")

      5.times do
        await_push(pushes)
        cycle!(session, tick).halted?.should be_false
        break if File.exists?(File.join(local, "theirs.rb"))
      end

      File.read(File.join(local, "theirs.rb")).should eq("written on the box")
      File.read(File.join(remote, "mine.rb")).should eq("written by the client")
      Dir.children(remote).size.should eq(22)

      cycle!(session, tick).quiet?.should be_true
    end
  end

  it "survives a push larger than a single batch" do
    in_watched_pair do |local, remote, session, pushes|
      Dir.mkdir_p(File.join(local, "app", "models"))
      Dir.mkdir_p(File.join(local, "db"))
      400.times { |index| File.write(File.join(local, "app", "models", "f#{index}.rb"), "class F#{index}; end") }
      File.write(File.join(local, "db", "structure.sql"), "-- schema")

      cycle!(session, tick)
      await_push(pushes)

      3.times do
        report = cycle!(session, tick)
        report.halted?.should be_false, "a cycle halted, which means a side looked emptied"
      end

      Dir.exists?(File.join(local, "app", "models")).should be_true, "the local tree was deleted"
      Dir.children(File.join(local, "app", "models")).size.should eq(400)
      Dir.children(File.join(remote, "app", "models")).size.should eq(400)
      File.exists?(File.join(local, "db", "structure.sql")).should be_true
    end
  end
end
