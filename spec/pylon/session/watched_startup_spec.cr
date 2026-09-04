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

private def in_pair(watch : Bool, create_remote : Bool = true, & : String, String, Session(LocalEndpoint, RemoteEndpoint), RemoteEndpoint ->) : Nil
  base = File.join(Dir.tempdir, "pylon-startup-#{Random::Secure.hex(8)}")
  local = File.join(base, "local")
  remote = File.join(base, "remote")
  Dir.mkdir_p(local)
  Dir.mkdir_p(remote) if create_remote

  client, socket = UNIXSocket.pair
  serve_remote_end(socket)

  begin
    endpoint = RemoteEndpoint.new(client, client, remote_configuration(remote, watch: watch), ::Channel(Nil).new(16))
    session = build_session(local_endpoint(local), endpoint)
    yield local, remote, session, endpoint
  ensure
    client.close
    socket.close
    FileUtils.rm_rf(base)
  end
end

describe "the first remote tree of a watched session" do
  it "arrives with the server's first push instead of a scan request" do
    in_pair(watch: true) do |local, remote, session, endpoint|
      File.write(File.join(remote, "pushed.rb"), "from the box")

      cycle!(session, tick)

      File.read(File.join(local, "pushed.rb")).should eq("from the box")
      endpoint.exchanges.should eq(1)
    end
  end

  it "costs a scan request when nothing pushes" do
    in_pair(watch: false) do |local, remote, session, endpoint|
      File.write(File.join(remote, "pushed.rb"), "from the box")

      cycle!(session, tick)

      File.read(File.join(local, "pushed.rb")).should eq("from the box")
      endpoint.exchanges.should eq(2)
    end
  end

  it "falls back to scan requests when the server cannot watch its root" do
    in_pair(watch: true, create_remote: false) do |local, remote, session, endpoint|
      File.write(File.join(local, "a.rb"), "a")

      cycle!(session, tick)

      File.read(File.join(remote, "a.rb")).should eq("a")
      endpoint.exchanges.should eq(1)

      File.write(File.join(remote, "b.rb"), "b")

      cycle!(session, tick)

      File.read(File.join(local, "b.rb")).should eq("b")
      endpoint.exchanges.should eq(3)
    end
  end
end
