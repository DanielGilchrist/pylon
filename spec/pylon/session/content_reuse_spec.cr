require "file_utils"
require "socket"
require "../../spec_helper"
require "../../../src/pylon/session/server"
require "../../../src/pylon/session/remote_endpoint"
require "../../../src/pylon/session/session"

include Pylon::Session

private class CountingIO < IO
  getter written = 0_i64

  def initialize(@inner : IO) : Nil
  end

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

private def in_counted_pair(& : String, String, Session(LocalEndpoint, RemoteEndpoint), CountingIO ->) : Nil
  base = File.join(Dir.tempdir, "pylon-reuse-#{Random::Secure.hex(8)}")
  local_root = File.join(base, "local")
  remote_root = File.join(base, "remote")
  Dir.mkdir_p(local_root)
  Dir.mkdir_p(remote_root)

  client, socket = UNIXSocket.pair
  server = Server.new(LocalEndpoint.new(remote_root), socket, socket)
  spawn { server.run }

  counting = CountingIO.new(client)

  begin
    session = Session.new(LocalEndpoint.new(local_root), RemoteEndpoint.new(client, counting))
    yield local_root, remote_root, session, counting
  ensure
    client.close
    socket.close
    FileUtils.rm_rf(base)
  end
end

private def tick : Int64
  Time.utc.to_unix_ns.to_i64 + Random.rand(1_000_000_i64)
end

private INCOMPRESSIBLE = Random.new(7).random_bytes(256 * 1024)

describe "content reuse across paths" do
  it "renames a file on the remote side without resending its bytes" do
    in_counted_pair do |local, remote, session, counting|
      Dir.mkdir_p(File.join(local, "a"))
      File.write(File.join(local, "a", "big.bin"), INCOMPRESSIBLE)

      cycle!(session, tick)

      FileUtils.mkdir_p(File.join(local, "z"))
      File.rename(File.join(local, "a", "big.bin"), File.join(local, "z", "big.bin"))

      before = counting.written
      cycle!(session, tick)

      File.read(File.join(remote, "z", "big.bin")).to_slice.should eq(INCOMPRESSIBLE)
      File.exists?(File.join(remote, "a", "big.bin")).should be_false
      (counting.written - before).should be < 32 * 1024
    end
  end

  it "reuses bytes even when the deletion sorts before the new path" do
    in_counted_pair do |local, remote, session, counting|
      Dir.mkdir_p(File.join(local, "z"))
      File.write(File.join(local, "z", "big.bin"), INCOMPRESSIBLE)

      cycle!(session, tick)

      FileUtils.mkdir_p(File.join(local, "a"))
      File.rename(File.join(local, "z", "big.bin"), File.join(local, "a", "big.bin"))

      before = counting.written
      cycle!(session, tick)

      File.read(File.join(remote, "a", "big.bin")).to_slice.should eq(INCOMPRESSIBLE)
      File.exists?(File.join(remote, "z", "big.bin")).should be_false
      (counting.written - before).should be < 32 * 1024
    end
  end

  it "renames a directory with enough files to engage the parallel writer" do
    in_counted_pair do |local, remote, session, counting|
      Dir.mkdir_p(File.join(local, "z"))
      pieces = Array(Bytes).new(24) { |index| INCOMPRESSIBLE[index * 8192, 8192] }
      pieces.each_with_index { |piece, index| File.write(File.join(local, "z", "file#{index}.bin"), piece) }

      cycle!(session, tick)

      File.rename(File.join(local, "z"), File.join(local, "a"))

      before = counting.written
      report = cycle!(session, tick)

      report.remote_outcomes.count { |outcome| !outcome.applied? }.should eq(0)
      pieces.each_with_index do |piece, index|
        File.read(File.join(remote, "a", "file#{index}.bin")).to_slice.should eq(piece)
      end
      Dir.exists?(File.join(remote, "z")).should be_false
      (counting.written - before).should be < 32 * 1024

      cycle!(session, tick).quiet?.should be_true
    end
  end

  it "reuses bytes for a copy while the original stays in place" do
    in_counted_pair do |local, remote, session, counting|
      File.write(File.join(local, "big.bin"), INCOMPRESSIBLE)

      cycle!(session, tick)

      File.write(File.join(local, "twin.bin"), INCOMPRESSIBLE)

      before = counting.written
      cycle!(session, tick)

      File.read(File.join(remote, "twin.bin")).to_slice.should eq(INCOMPRESSIBLE)
      File.read(File.join(remote, "big.bin")).to_slice.should eq(INCOMPRESSIBLE)
      (counting.written - before).should be < 32 * 1024
    end
  end

  it "converges when a rename lands on the local side" do
    in_counted_pair do |local, remote, session, _counting|
      Dir.mkdir_p(File.join(local, "a"))
      File.write(File.join(local, "a", "big.bin"), INCOMPRESSIBLE)

      cycle!(session, tick)

      Dir.mkdir_p(File.join(remote, "z"))
      File.rename(File.join(remote, "a", "big.bin"), File.join(remote, "z", "big.bin"))

      cycle!(session, tick)

      File.read(File.join(local, "z", "big.bin")).to_slice.should eq(INCOMPRESSIBLE)
      File.exists?(File.join(local, "a", "big.bin")).should be_false
    end
  end
end
