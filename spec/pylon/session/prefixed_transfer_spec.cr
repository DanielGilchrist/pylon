{% skip_file unless flag?(:darwin) %}

require "digest/sha256"
require "file_utils"
require "socket"
require "../../spec_helper"
require "../../../src/pylon/session/server"
require "../../../src/pylon/session/remote_endpoint"
require "../../../src/pylon/session/session"
require "../../../src/pylon/session/content_store"
require "../../support/remote_end"

include Pylon::Session

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
  local : String,
  remote : String,
  session : Session(LocalEndpoint, RemoteEndpoint),
  endpoint : RemoteEndpoint,
  metered : MeteredIO,
  left : LocalEndpoint,
  store : ContentStore

private def in_retaining_pair(retain_from_start : Bool = true, & : Pair ->) : Nil
  base = File.join(Dir.tempdir, "pylon-prefixed-#{Random::Secure.hex(8)}")
  local_root = File.join(base, "local")
  remote_root = File.join(base, "remote")
  Dir.mkdir_p(local_root)
  Dir.mkdir_p(remote_root)

  store = ContentStore.open(File.join(base, "store"), local_root)
  raise "the store could not be opened: #{store.reason}" if store.is_a?(ContentStore::Unavailable)

  client, socket = UNIXSocket.pair
  serve_remote_end(socket)

  metered = MeteredIO.new(client)
  left = local_endpoint(local_root)
  left.store = store if retain_from_start
  endpoint = RemoteEndpoint.new(metered, metered, remote_configuration(remote_root), resume: nil)

  begin
    yield Pair.new(local_root, remote_root, build_session(left, endpoint), endpoint, metered, left, store)
  ensure
    client.close
    socket.close
    FileUtils.rm_rf(base)
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

describe "patches against retained copies" do
  it "pushes an edit as a patch against the retained copy without asking for signatures" do
    in_retaining_pair do |pair|
      File.write(File.join(pair.local, "big.bin"), INCOMPRESSIBLE)
      cycle!(pair.session, tick)

      edited = with_byte_flipped(INCOMPRESSIBLE)
      File.write(File.join(pair.local, "big.bin"), edited)
      written_before = pair.metered.written
      exchanges_before = pair.endpoint.exchanges

      cycle!(pair.session, tick)

      File.read(File.join(pair.remote, "big.bin")).to_slice.should eq(edited)
      (pair.metered.written - written_before).should be < 4 * 1024
      (pair.endpoint.exchanges - exchanges_before).should eq(2)
      cycle!(pair.session, tick).quiet?.should be_true
    end
  end

  it "patches a file too small for block deltas" do
    in_retaining_pair do |pair|
      File.write(File.join(pair.local, "small.bin"), SMALL)
      cycle!(pair.session, tick)

      edited = with_byte_flipped(SMALL)
      File.write(File.join(pair.local, "small.bin"), edited)
      written_before = pair.metered.written

      cycle!(pair.session, tick)

      File.read(File.join(pair.remote, "small.bin")).to_slice.should eq(edited)
      (pair.metered.written - written_before).should be < 2 * 1024
    end
  end

  it "falls back to signatures until the base has been retained" do
    in_retaining_pair(retain_from_start: false) do |pair|
      File.write(File.join(pair.local, "big.bin"), INCOMPRESSIBLE)
      cycle!(pair.session, tick)
      pair.left.store = pair.store

      once = with_byte_flipped(INCOMPRESSIBLE)
      File.write(File.join(pair.local, "big.bin"), once)
      exchanges_before = pair.endpoint.exchanges
      cycle!(pair.session, tick)

      File.read(File.join(pair.remote, "big.bin")).to_slice.should eq(once)
      (pair.endpoint.exchanges - exchanges_before).should eq(4)

      twice = with_byte_flipped(once)
      File.write(File.join(pair.local, "big.bin"), twice)
      exchanges_before = pair.endpoint.exchanges
      cycle!(pair.session, tick)

      File.read(File.join(pair.remote, "big.bin")).to_slice.should eq(twice)
      (pair.endpoint.exchanges - exchanges_before).should eq(2)
    end
  end

  it "keeps every version it has hashed until the orphan bound prunes it" do
    in_retaining_pair do |pair|
      original = Digest::SHA256.digest(INCOMPRESSIBLE)
      edited = with_byte_flipped(INCOMPRESSIBLE)
      replacement = Digest::SHA256.digest(edited)

      File.write(File.join(pair.local, "a.bin"), INCOMPRESSIBLE)
      cycle!(pair.session, tick)
      pair.store.holds?(original).should be_true

      File.write(File.join(pair.local, "a.bin"), edited)
      cycle!(pair.session, tick)
      pair.store.holds?(original).should be_true
      pair.store.holds?(replacement).should be_true

      File.delete(File.join(pair.local, "a.bin"))
      cycle!(pair.session, tick)
      String.new(pair.store.content(replacement) || Bytes.empty).to_slice.should eq(edited)
    end
  end
end
