require "file_utils"
require "socket"
require "../../spec_helper"
require "../../../src/pylon/session/checkpoint"
require "../../../src/pylon/session/server"
require "../../../src/pylon/session/remote_endpoint"
require "../../../src/pylon/session/session"
require "../../support/remote_end"

include Pylon::Session

private class CountingReader < IO
  def initialize(@inner : IO) : Nil
  end

  getter read_bytes = 0_i64

  def read(slice : Bytes) : Int32
    filled = @inner.read(slice)
    @read_bytes += filled
    filled
  end

  def write(slice : Bytes) : Nil
    @inner.write(slice)
  end
end

private record Ends, local : String, remote : String, state : String

private def with_roots(& : Ends ->) : Nil
  base = File.join(Dir.tempdir, "pylon-resume-#{Random::Secure.hex(8)}")
  ends = Ends.new(
    File.join(base, "local"),
    File.join(base, "remote"),
    File.join(base, "remote-state"),
  )
  Dir.mkdir_p(ends.local)
  Dir.mkdir_p(ends.remote)

  begin
    yield ends
  ensure
    FileUtils.rm_rf(base)
  end
end

private def connect(
  ends : Ends,
  resume : Core::Entry?,
  & : Session(LocalEndpoint, RemoteEndpoint), RemoteEndpoint, CountingReader ->
) : Nil
  client, socket = UNIXSocket.pair
  serve_remote_end(socket)
  counting = CountingReader.new(client)

  configure = Pylon::Wire::Message::Configure.new(
    root: ends.remote,
    ignores: Array(String).new,
    compression: Pylon::Compress::Zstd::DEFAULT_LEVEL,
    brand: Pylon::Brand::DEFAULT,
    state: ends.state,
    watch: false,
    known: (Digests.fingerprint(resume) if resume),
  )

  begin
    endpoint = RemoteEndpoint.new(counting, client, configure, resume: resume)
    yield build_session(local_endpoint(ends.local), endpoint), endpoint, counting
  ensure
    client.close
    socket.close
  end
end

private def tick : Int64
  Time.utc.to_unix_ns.to_i64 + Random.rand(1_000_000_i64)
end

private def wait_for_state(path : String) : Nil
  50.times do
    return if File.exists?(path)

    sleep(20.milliseconds)
  end

  raise "the server never saved its state at #{path}"
end

describe "resuming from a persisted remote tree" do
  it "receives only what changed since the tree both sides persisted" do
    with_roots do |ends|
      300.times { |index| File.write(File.join(ends.remote, "file_#{index}.rb"), "body #{index}") }

      exchanged = nil
      connect(ends, nil) do |session, endpoint, _|
        cycle!(session, tick)
        exchanged = endpoint.tree
      end
      wait_for_state(ends.state)

      File.write(File.join(ends.remote, "file_300.rb"), "late arrival")

      connect(ends, exchanged) do |session, _, counting|
        cycle!(session, tick)

        File.read(File.join(ends.local, "file_300.rb")).should eq("late arrival")
        counting.read_bytes.should be < 2048
      end
    end
  end

  it "falls back to the whole tree when the fingerprints differ" do
    with_roots do |ends|
      300.times { |index| File.write(File.join(ends.remote, "file_#{index}.rb"), "body #{index}") }

      connect(ends, nil) do |session, _, _|
        cycle!(session, tick)
      end
      wait_for_state(ends.state)

      stale = Directory.new({"other.rb" => Fixtures.f1})

      connect(ends, stale) do |session, _, counting|
        cycle!(session, tick)

        Dir.children(ends.local).size.should eq(300)
        counting.read_bytes.should be > 8192
      end
    end
  end
end
