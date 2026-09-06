require "../../spec_helper"

require "socket"
require "../../support/remote_end"

private alias RemoteEndpoint = Pylon::Session::RemoteEndpoint
private alias Session = Pylon::Session::Session
private alias LocalEndpoint = Pylon::Session::LocalEndpoint
private alias Discard = Pylon::Discard

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

private record Ends, local : Sandbox, remote : Sandbox, state : String

private def with_roots(& : Ends ->) : Nil
  Sandbox.open do |sandbox|
    yield Ends.new(
      sandbox.directory("local"),
      sandbox.directory("remote"),
      sandbox.path("remote-state"),
    )
  end
end

private def connect(
  ends : Ends,
  resume : Pylon::Core::Entry?,
  & : Session(LocalEndpoint, RemoteEndpoint, Discard), RemoteEndpoint, CountingReader ->
) : Nil
  client, socket = UNIXSocket.pair
  serve_remote_end(socket)
  counting = CountingReader.new(client)

  configure = Pylon::Wire::Message::Configure.new(
    root: ends.remote.root,
    ignores: Array(String).new,
    compression: Pylon::Compress::Zstd::DEFAULT_LEVEL,
    brand: Pylon::Brand::DEFAULT,
    state: ends.state,
    watch: false,
    tree_fingerprint: (Pylon::Core::Digests.fingerprint(resume) if resume),
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
      300.times { |index| ends.remote.write("file_#{index}.rb", "body #{index}") }

      shared_tree = nil
      connect(ends, nil) do |session, endpoint, _|
        cycle!(session, tick)
        shared_tree = endpoint.tree
      end
      wait_for_state(ends.state)

      ends.remote.write("file_300.rb", "late arrival")

      connect(ends, shared_tree) do |session, _, counting|
        cycle!(session, tick)

        ends.local.read("file_300.rb").should eq("late arrival")
        counting.read_bytes.should be < 2048
      end
    end
  end

  it "falls back to the whole tree when the fingerprints differ" do
    with_roots do |ends|
      300.times { |index| ends.remote.write("file_#{index}.rb", "body #{index}") }

      connect(ends, nil) do |session, _, _|
        cycle!(session, tick)
      end
      wait_for_state(ends.state)

      stale = Pylon::Core::Directory.new({"other.rb" => Fixtures.f1})

      connect(ends, stale) do |session, _, counting|
        cycle!(session, tick)

        ends.local.children.size.should eq(300)
        counting.read_bytes.should be > 8192
      end
    end
  end
end
