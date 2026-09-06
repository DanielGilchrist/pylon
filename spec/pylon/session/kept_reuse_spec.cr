require "../../spec_helper"

require "file_utils"
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
  & : String, String, Paired, RemoteEndpoint, CountingIO ->
) : Nil
  base = File.join(Dir.tempdir, "pylon-kept-#{Random::Secure.hex(8)}")
  local_root = File.join(base, "local")
  remote_root = File.join(base, "remote")
  Dir.mkdir_p(local_root)
  Dir.mkdir_p(remote_root)

  client, socket = UNIXSocket.pair
  serve_remote_end(socket)
  counting = CountingIO.new(client)

  begin
    endpoint = RemoteEndpoint.new(
      client,
      counting,
      remote_configuration(remote_root, state: File.join(base, "remote-state")),
      resume: nil,
    )
    session = build_session(local_endpoint(local_root), endpoint)
    yield local_root, remote_root, session, endpoint, counting
  ensure
    client.close
    socket.close
    FileUtils.rm_rf(base)
  end
end

private def tick : Int64
  Time.utc.to_unix_ns.to_i64 + Random.rand(1_000_000_i64)
end

private LARGE = Random.new(11).random_bytes(300 * 1024)

describe "recovering content the receiver removed earlier" do
  it "re-adds a deleted file without sending its bytes again" do
    in_keeping_pair do |local, remote, session, endpoint, counting|
      File.write(File.join(local, "big.bin"), LARGE)
      cycle!(session, tick)

      File.delete(File.join(local, "big.bin"))
      cycle!(session, tick)
      File.exists?(File.join(remote, "big.bin")).should be_false

      File.write(File.join(local, "big.bin"), LARGE)
      before = counting.written
      exchanges = endpoint.exchanges
      cycle!(session, tick)

      File.read(File.join(remote, "big.bin")).to_slice.should eq(LARGE)
      (counting.written - before).should be < 8 * 1024
      (endpoint.exchanges - exchanges).should eq(3)
      cycle!(session, tick).quiet?.should be_true
    end
  end

  it "restores an overwritten file to its earlier content without sending it" do
    in_keeping_pair do |local, remote, session, _, counting|
      File.write(File.join(local, "big.bin"), LARGE)
      cycle!(session, tick)

      File.write(File.join(local, "big.bin"), Random.new(12).random_bytes(300 * 1024))
      cycle!(session, tick)

      File.write(File.join(local, "big.bin"), LARGE)
      before = counting.written
      cycle!(session, tick)

      File.read(File.join(remote, "big.bin")).to_slice.should eq(LARGE)
      (counting.written - before).should be < 8 * 1024
    end
  end

  it "does not spend a round trip asking about a small re-add" do
    in_keeping_pair do |local, remote, session, endpoint, _|
      File.write(File.join(local, "small.rb"), "puts 1")
      cycle!(session, tick)
      File.delete(File.join(local, "small.rb"))
      cycle!(session, tick)

      File.write(File.join(local, "small.rb"), "puts 1")
      exchanges = endpoint.exchanges
      cycle!(session, tick)

      File.read(File.join(remote, "small.rb")).should eq("puts 1")
      (endpoint.exchanges - exchanges).should eq(2)
    end
  end
end
