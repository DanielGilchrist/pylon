require "file_utils"
require "socket"
require "../../spec_helper"
require "../../../src/pylon/session/server"
require "../../../src/pylon/session/remote_endpoint"
require "../../../src/pylon/session/session"

include Pylon::Session

private def in_remote_pair(& : String, String, Session(LocalEndpoint, RemoteEndpoint) ->)
  base = File.join(Dir.tempdir, "pylon-remote-#{Random::Secure.hex(8)}")
  local_root = File.join(base, "local")
  remote_root = File.join(base, "remote")
  Dir.mkdir_p(local_root)
  Dir.mkdir_p(remote_root)

  client, socket = UNIXSocket.pair
  server = Server.new(LocalEndpoint.new(remote_root), socket, socket)
  spawn { server.run }

  begin
    session = Session.new(LocalEndpoint.new(local_root), RemoteEndpoint.new(client, client))
    yield local_root, remote_root, session
  ensure
    client.close
    socket.close
    FileUtils.rm_rf(base)
  end
end

private def tick : Int64
  Time.utc.to_unix_ns.to_i64 + Random.rand(1_000_000_i64)
end

describe "a session over the wire protocol" do
  it "copies a file to the remote side" do
    in_remote_pair do |local, remote, session|
      File.write(File.join(local, "hello.rb"), "puts 1")

      session.cycle(tick)

      File.read(File.join(remote, "hello.rb")).should eq("puts 1")
    end
  end

  it "copies a file back from the remote side" do
    in_remote_pair do |local, remote, session|
      Dir.mkdir_p(File.join(remote, "lib"))
      File.write(File.join(remote, "lib", "thing.rb"), "puts 2")

      session.cycle(tick)

      File.read(File.join(local, "lib", "thing.rb")).should eq("puts 2")
    end
  end

  it "settles after one cycle" do
    in_remote_pair do |local, _, session|
      File.write(File.join(local, "a.rb"), "a")
      File.write(File.join(local, "b.rb"), "b")

      session.cycle(tick)
      session.cycle(tick).quiet?.should be_true
    end
  end

  it "moves many files in a single cycle" do
    in_remote_pair do |local, remote, session|
      200.times { |index| File.write(File.join(local, "file_#{index}.rb"), "body #{index}") }

      session.cycle(tick)

      Dir.children(remote).size.should eq(200)
      File.read(File.join(remote, "file_199.rb")).should eq("body 199")
    end
  end

  it "propagates a deletion across the wire" do
    in_remote_pair do |local, remote, session|
      File.write(File.join(local, "temp.rb"), "x")
      session.cycle(tick)

      File.delete(File.join(local, "temp.rb"))
      session.cycle(tick)

      File.exists?(File.join(remote, "temp.rb")).should be_false
    end
  end

  it "propagates the executable bit across the wire" do
    in_remote_pair do |local, remote, session|
      path = File.join(local, "run.sh")
      File.write(path, "#!/bin/sh\n")
      File.chmod(path, 0o755)

      session.cycle(tick)

      File.info(File.join(remote, "run.sh")).permissions.value.should eq(0o755)
    end
  end

  it "reports a conflict without touching either side" do
    in_remote_pair do |local, remote, session|
      File.write(File.join(local, "shared.rb"), "original")
      session.cycle(tick)

      File.write(File.join(local, "shared.rb"), "from local")
      File.write(File.join(remote, "shared.rb"), "from remote")
      report = session.cycle(tick)

      report.conflicts.map(&.root).should eq(["shared.rb"])
      File.read(File.join(local, "shared.rb")).should eq("from local")
      File.read(File.join(remote, "shared.rb")).should eq("from remote")
    end
  end
end

describe "a session whose remote pushes tree updates" do
  it "still sees remote changes when no pusher exists, at the cost of a round trip" do
    in_remote_pair do |local, remote, session|
      File.write(File.join(remote, "pushed.rb"), "from the box")

      session.cycle(tick)

      File.read(File.join(local, "pushed.rb")).should eq("from the box")
    end
  end

  it "keeps its cached remote tree correct after its own write" do
    in_remote_pair do |local, remote, session|
      File.write(File.join(local, "one.rb"), "1")
      session.cycle(tick)
      session.cycle(tick).quiet?.should be_true

      File.write(File.join(local, "two.rb"), "2")
      session.cycle(tick)

      File.read(File.join(remote, "two.rb")).should eq("2")
      session.cycle(tick).quiet?.should be_true
    end
  end
end
