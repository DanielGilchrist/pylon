require "../../spec_helper"

require "socket"
require "../../support/remote_end"

private alias RemoteEndpoint = Pylon::Session::RemoteEndpoint
private alias Session = Pylon::Session::Session
private alias LocalEndpoint = Pylon::Session::LocalEndpoint
private alias Discard = Pylon::Discard

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

private def in_counted_pair(
  & : Sandbox, Sandbox, Session(LocalEndpoint, RemoteEndpoint, Discard), CountingIO ->
) : Nil
  Sandbox.open do |sandbox|
    local_root = sandbox.directory("local")
    remote_root = sandbox.directory("remote")

    client, socket = UNIXSocket.pair
    serve_remote_end(socket)

    counting = CountingIO.new(client)

    begin
      session = build_session(
        local_endpoint(local_root),
        RemoteEndpoint.new(client, counting, remote_configuration(remote_root), resume: nil),
      )
      yield local_root, remote_root, session, counting
    ensure
      client.close
      socket.close
    end
  end
end

private def tick : Int64
  Time.utc.to_unix_ns.to_i64 + Random.rand(1_000_000_i64)
end

private INCOMPRESSIBLE = Random.new(7).random_bytes(256 * 1024)

describe "content reuse across paths" do
  it "renames a file on the remote side without resending its bytes" do
    in_counted_pair do |local, remote, session, counting|
      local.directory("a")
      local.write("a/big.bin", INCOMPRESSIBLE)

      cycle!(session, tick)

      local.directory("z")
      local.rename("a/big.bin", "z/big.bin")

      before = counting.written
      cycle!(session, tick)

      remote.read("z/big.bin").to_slice.should eq(INCOMPRESSIBLE)
      remote.exists?("a/big.bin").should be_false
      (counting.written - before).should be < 32 * 1024
    end
  end

  it "reuses bytes even when the deletion sorts before the new path" do
    in_counted_pair do |local, remote, session, counting|
      local.directory("z")
      local.write("z/big.bin", INCOMPRESSIBLE)

      cycle!(session, tick)

      local.directory("a")
      local.rename("z/big.bin", "a/big.bin")

      before = counting.written
      cycle!(session, tick)

      remote.read("a/big.bin").to_slice.should eq(INCOMPRESSIBLE)
      remote.exists?("z/big.bin").should be_false
      (counting.written - before).should be < 32 * 1024
    end
  end

  it "renames a directory with enough files to engage the parallel writer" do
    in_counted_pair do |local, remote, session, counting|
      local.directory("z")
      pieces = Array(Bytes).new(24) { |index| INCOMPRESSIBLE[index * 8192, 8192] }
      pieces.each_with_index do |piece, index|
        local.write("z/file#{index}.bin", piece)
      end

      cycle!(session, tick)

      local.rename("z", "a")

      before = counting.written
      report = cycle!(session, tick)

      report.remote_outcomes.count { |outcome| !outcome.applied? }.should eq(0)
      pieces.each_with_index do |piece, index|
        remote.read("a/file#{index}.bin").to_slice.should eq(piece)
      end
      remote.directory?("z").should be_false
      (counting.written - before).should be < 32 * 1024

      cycle!(session, tick).quiet?.should be_true
    end
  end

  it "reuses bytes for a copy while the original stays in place" do
    in_counted_pair do |local, remote, session, counting|
      local.write("big.bin", INCOMPRESSIBLE)

      cycle!(session, tick)

      local.write("twin.bin", INCOMPRESSIBLE)

      before = counting.written
      cycle!(session, tick)

      remote.read("twin.bin").to_slice.should eq(INCOMPRESSIBLE)
      remote.read("big.bin").to_slice.should eq(INCOMPRESSIBLE)
      (counting.written - before).should be < 32 * 1024
    end
  end

  it "converges when a rename lands on the local side" do
    in_counted_pair do |local, remote, session, _counting|
      local.directory("a")
      local.write("a/big.bin", INCOMPRESSIBLE)

      cycle!(session, tick)

      remote.directory("z")
      remote.rename("a/big.bin", "z/big.bin")

      cycle!(session, tick)

      local.read("z/big.bin").to_slice.should eq(INCOMPRESSIBLE)
      local.exists?("a/big.bin").should be_false
    end
  end
end
