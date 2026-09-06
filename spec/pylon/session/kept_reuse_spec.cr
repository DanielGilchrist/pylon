require "../../spec_helper"

require "socket"
require "../../support/remote_end"

private alias LocalEndpoint = Pylon::Session::LocalEndpoint
private alias RemoteEndpoint = Pylon::Session::RemoteEndpoint

private alias Paired = Pylon::Session::Session(LocalEndpoint, RemoteEndpoint, Pylon::Discard)

private class CountingIO < IO
  def initialize(@inner : IO) : Nil
  end

  getter written = 0_i64

  def read(slice : Bytes) : Int32
    @inner.read(slice)
  end

  def write(slice : Bytes) : Nil
    @written += slice.size
    @inner.write(slice)
  end

  def flush : Nil
    @inner.flush
  end
end

private def in_keeping_pair(
  & : Sandbox, Sandbox, Paired, RemoteEndpoint, CountingIO ->
) : Nil
  Sandbox.open do |sandbox|
    local_root = sandbox.directory("local")
    remote_root = sandbox.directory("remote")

    client, socket = UNIXSocket.pair
    serve_remote_end(socket)
    counting = CountingIO.new(client)

    begin
      endpoint = RemoteEndpoint.new(
        client,
        counting,
        remote_configuration(remote_root, state: sandbox.path("remote-state")),
        resume: nil,
      )
      session = build_session(local_endpoint(local_root), endpoint)
      yield local_root, remote_root, session, endpoint, counting
    ensure
      client.close
      socket.close
    end
  end
end

private def tick : Int64
  Time.utc.to_unix_ns.to_i64 + Random.rand(1_000_000_i64)
end

private LARGE = Random.new(11).random_bytes(300 * 1024)

describe "recovering content the receiver removed earlier" do
  it "re-adds a deleted file without sending its bytes again" do
    in_keeping_pair do |local, remote, session, endpoint, counting|
      local.write("big.bin", LARGE)
      cycle!(session, tick)

      local.remove("big.bin")
      cycle!(session, tick)
      remote.exists?("big.bin").should be_false

      local.write("big.bin", LARGE)
      before = counting.written
      exchanges = endpoint.exchanges
      cycle!(session, tick)

      remote.read("big.bin").to_slice.should eq(LARGE)
      (counting.written - before).should be < 8 * 1024
      (endpoint.exchanges - exchanges).should eq(3)
      cycle!(session, tick).quiet?.should be_true
    end
  end

  it "restores an overwritten file to its earlier content without sending it" do
    in_keeping_pair do |local, remote, session, _, counting|
      local.write("big.bin", LARGE)
      cycle!(session, tick)

      local.write("big.bin", Random.new(12).random_bytes(300 * 1024))
      cycle!(session, tick)

      local.write("big.bin", LARGE)
      before = counting.written
      cycle!(session, tick)

      remote.read("big.bin").to_slice.should eq(LARGE)
      (counting.written - before).should be < 8 * 1024
    end
  end

  it "does not spend a round trip asking about a small re-add" do
    in_keeping_pair do |local, remote, session, endpoint, _|
      local.write("small.rb", "puts 1")
      cycle!(session, tick)
      local.remove("small.rb")
      cycle!(session, tick)

      local.write("small.rb", "puts 1")
      exchanges = endpoint.exchanges
      cycle!(session, tick)

      remote.read("small.rb").should eq("puts 1")
      (endpoint.exchanges - exchanges).should eq(2)
    end
  end
end
