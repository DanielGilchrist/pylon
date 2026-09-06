require "../../spec_helper"

require "socket"
require "../../support/remote_end"

private alias RemoteEndpoint = Pylon::Session::RemoteEndpoint
private alias Session = Pylon::Session::Session
private alias LocalEndpoint = Pylon::Session::LocalEndpoint
private alias Discard = Pylon::Discard

private def tick : Int64
  Time.utc.to_unix_ns.to_i64 + Random.rand(1_000_000_i64)
end

private def in_pair(
  watch : Bool,
  create_remote : Bool = true,
  & : Sandbox, Sandbox, Session(LocalEndpoint, RemoteEndpoint, Discard), RemoteEndpoint ->
) : Nil
  Sandbox.open do |sandbox|
    local = sandbox.directory("local")
    remote = create_remote ? sandbox.directory("remote") : Sandbox.new(sandbox.path("remote"))

    client, socket = UNIXSocket.pair
    serve_remote_end(socket)

    begin
      endpoint = RemoteEndpoint.new(
        client,
        client,
        remote_configuration(remote, watch: watch),
        ::Channel(Nil).new(16),
        resume: nil,
      )
      session = build_session(local_endpoint(local), endpoint)
      yield local, remote, session, endpoint
    ensure
      client.close
      socket.close
    end
  end
end

describe "the first remote tree of a session" do
  it "arrives with the server's first push instead of a scan request" do
    in_pair(watch: true) do |local, remote, session, endpoint|
      remote.write("pushed.rb", "from the box")

      cycle!(session, tick)

      local.read("pushed.rb").should eq("from the box")
      endpoint.exchanges.should eq(1)
    end
  end

  it "arrives with the server's first push even when nobody is watching" do
    in_pair(watch: false) do |local, remote, session, endpoint|
      remote.write("pushed.rb", "from the box")

      cycle!(session, tick)

      local.read("pushed.rb").should eq("from the box")
      endpoint.exchanges.should eq(1)

      remote.write("later.rb", "also from the box")

      cycle!(session, tick)

      local.read("later.rb").should eq("also from the box")
      endpoint.exchanges.should eq(3)
    end
  end

  it "falls back to scan requests when the server cannot watch its root" do
    in_pair(watch: true, create_remote: false) do |local, remote, session, endpoint|
      local.write("a.rb", "a")

      cycle!(session, tick)

      remote.read("a.rb").should eq("a")
      endpoint.exchanges.should eq(1)

      remote.write("b.rb", "b")

      cycle!(session, tick)

      local.read("b.rb").should eq("b")
      endpoint.exchanges.should eq(3)
    end
  end
end
