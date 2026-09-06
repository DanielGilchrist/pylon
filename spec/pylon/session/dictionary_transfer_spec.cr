require "../../spec_helper"

Pylon::Platform.skip_file_unless :macos

require "digest/sha256"
require "socket"
require "../../support/remote_end"

private alias ContentStore = Pylon::Session::ContentStore
private alias LocalEndpoint = Pylon::Session::LocalEndpoint
private alias RemoteEndpoint = Pylon::Session::RemoteEndpoint

private class MeteredIO < IO
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

private record Pair,
  local : Sandbox,
  remote : Sandbox,
  session : Pylon::Session::Session(LocalEndpoint, RemoteEndpoint, Pylon::Discard),
  endpoint : RemoteEndpoint,
  metered : MeteredIO,
  left : LocalEndpoint,
  kept : ContentStore

private def in_keeping_pair(keep_from_start : Bool = true, & : Pair ->) : Nil
  Sandbox.open do |sandbox|
    local_root = sandbox.directory("local")
    remote_root = sandbox.directory("remote")

    kept = ContentStore.open(sandbox.path("store"), local_root.root)
    raise "the store could not be opened: #{kept.reason}" if kept.is_a?(Pylon::Problem)

    client, socket = UNIXSocket.pair
    serve_remote_end(socket)

    metered = MeteredIO.new(client)
    left = local_endpoint(local_root)
    left.kept = kept if keep_from_start
    endpoint = RemoteEndpoint.new(metered, metered, remote_configuration(remote_root), resume: nil)

    begin
      yield Pair.new(
        local_root,
        remote_root,
        build_session(left, endpoint),
        endpoint,
        metered,
        left,
        kept,
      )
    ensure
      client.close
      socket.close
    end
  end
end

private def tick : Int64
  Time.utc.to_unix_ns.to_i64 + Random.rand(1_000_000_i64)
end

private INCOMPRESSIBLE = Random.new(51).random_bytes(256 * 1024)
private SMALL          = Random.new(52).random_bytes(4 * 1024)

private def with_byte_flipped(content : Bytes) : Bytes
  edited = content.dup
  edited[edited.size // 2] ^= 0xFF_u8
  edited
end

describe "dictionary frames against kept copies" do
  it "pushes an edit as a dictionary frame against the kept copy without asking for checksums" do
    in_keeping_pair do |pair|
      pair.local.write("big.bin", INCOMPRESSIBLE)
      cycle!(pair.session, tick)

      edited = with_byte_flipped(INCOMPRESSIBLE)
      pair.local.write("big.bin", edited)
      written_before = pair.metered.written
      exchanges_before = pair.endpoint.exchanges

      cycle!(pair.session, tick)

      pair.remote.read("big.bin").to_slice.should eq(edited)
      (pair.metered.written - written_before).should be < 4 * 1024
      (pair.endpoint.exchanges - exchanges_before).should eq(2)
      cycle!(pair.session, tick).quiet?.should be_true
    end
  end

  it "compresses a file too small for splicing against its kept copy" do
    in_keeping_pair do |pair|
      pair.local.write("small.bin", SMALL)
      cycle!(pair.session, tick)

      edited = with_byte_flipped(SMALL)
      pair.local.write("small.bin", edited)
      written_before = pair.metered.written

      cycle!(pair.session, tick)

      pair.remote.read("small.bin").to_slice.should eq(edited)
      (pair.metered.written - written_before).should be < 2 * 1024
    end
  end

  it "falls back to checksums until the base has been kept" do
    in_keeping_pair(keep_from_start: false) do |pair|
      pair.local.write("big.bin", INCOMPRESSIBLE)
      cycle!(pair.session, tick)
      pair.left.kept = pair.kept

      once = with_byte_flipped(INCOMPRESSIBLE)
      pair.local.write("big.bin", once)
      exchanges_before = pair.endpoint.exchanges
      cycle!(pair.session, tick)

      pair.remote.read("big.bin").to_slice.should eq(once)
      (pair.endpoint.exchanges - exchanges_before).should eq(4)

      twice = with_byte_flipped(once)
      pair.local.write("big.bin", twice)
      exchanges_before = pair.endpoint.exchanges
      cycle!(pair.session, tick)

      pair.remote.read("big.bin").to_slice.should eq(twice)
      (pair.endpoint.exchanges - exchanges_before).should eq(2)
    end
  end

  it "keeps every version it has hashed until the orphan bound prunes it" do
    in_keeping_pair do |pair|
      original = Digest::SHA256.digest(INCOMPRESSIBLE)
      edited = with_byte_flipped(INCOMPRESSIBLE)
      replacement = Digest::SHA256.digest(edited)

      pair.local.write("a.bin", INCOMPRESSIBLE)
      cycle!(pair.session, tick)
      pair.kept.holds?(original).should be_true

      pair.local.write("a.bin", edited)
      cycle!(pair.session, tick)
      pair.kept.holds?(original).should be_true
      pair.kept.holds?(replacement).should be_true

      pair.local.remove("a.bin")
      cycle!(pair.session, tick)
      String.new(pair.kept.content(replacement) || Bytes.empty).to_slice.should eq(edited)
    end
  end
end
