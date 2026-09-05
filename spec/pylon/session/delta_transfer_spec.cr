require "file_utils"
require "socket"
require "../../spec_helper"
require "../../../src/pylon/session/server"
require "../../../src/pylon/session/remote_endpoint"
require "../../../src/pylon/session/session"
require "../../support/remote_end"

include Pylon::Session

private class MeteredIO < IO
  def initialize(@inner : IO) : Nil
  end

  getter written = 0_i64
  getter consumed = 0_i64

  def read(slice : Bytes) : Int32
    filled = @inner.read(slice)
    @consumed += filled
    filled
  end

  def write(slice : Bytes) : Nil
    @written += slice.size
    @inner.write(slice)
  end

  def flush : Nil
    @inner.flush
  end
end

private def in_metered_pair(
  & : String, String, Session(LocalEndpoint, RemoteEndpoint), MeteredIO ->
) : Nil
  base = File.join(Dir.tempdir, "pylon-delta-#{Random::Secure.hex(8)}")
  local_root = File.join(base, "local")
  remote_root = File.join(base, "remote")
  Dir.mkdir_p(local_root)
  Dir.mkdir_p(remote_root)

  client, socket = UNIXSocket.pair
  serve_remote_end(socket)

  metered = MeteredIO.new(client)

  begin
    session = build_session(
      local_endpoint(local_root),
      RemoteEndpoint.new(metered, metered, remote_configuration(remote_root), resume: nil),
    )
    yield local_root, remote_root, session, metered
  ensure
    client.close
    socket.close
    FileUtils.rm_rf(base)
  end
end

private def tick : Int64
  Time.utc.to_unix_ns.to_i64 + Random.rand(1_000_000_i64)
end

private INCOMPRESSIBLE = Random.new(21).random_bytes(256 * 1024)
private APPENDED       = Random.new(22).random_bytes(64)

private def appended_copy : Bytes
  edited = Bytes.new(INCOMPRESSIBLE.size + APPENDED.size)
  INCOMPRESSIBLE.copy_to(edited)
  APPENDED.copy_to(edited[INCOMPRESSIBLE.size, APPENDED.size])
  edited
end

describe "delta transfer over the wire protocol" do
  it "pushes an append as a delta instead of the whole file" do
    in_metered_pair do |local, remote, session, metered|
      File.write(File.join(local, "big.bin"), INCOMPRESSIBLE)

      cycle!(session, tick)

      edited = appended_copy
      File.write(File.join(local, "big.bin"), edited)

      before = metered.written
      cycle!(session, tick)

      File.read(File.join(remote, "big.bin")).to_slice.should eq(edited)
      (metered.written - before).should be < 32 * 1024

      cycle!(session, tick).quiet?.should be_true
    end
  end

  it "pulls an append as a delta instead of the whole file" do
    in_metered_pair do |local, remote, session, metered|
      File.write(File.join(remote, "big.bin"), INCOMPRESSIBLE)

      cycle!(session, tick)

      edited = appended_copy
      File.write(File.join(remote, "big.bin"), edited)

      before = metered.consumed
      cycle!(session, tick)

      File.read(File.join(local, "big.bin")).to_slice.should eq(edited)
      (metered.consumed - before).should be < 32 * 1024

      cycle!(session, tick).quiet?.should be_true
    end
  end

  it "falls back to the full content when nothing of the old file survives" do
    in_metered_pair do |local, remote, session, _metered|
      File.write(File.join(local, "big.bin"), INCOMPRESSIBLE)

      cycle!(session, tick)

      rewritten = Random.new(23).random_bytes(64 * 1024)
      File.write(File.join(local, "big.bin"), rewritten)

      cycle!(session, tick)

      File.read(File.join(remote, "big.bin")).to_slice.should eq(rewritten)
      cycle!(session, tick).quiet?.should be_true
    end
  end
end
