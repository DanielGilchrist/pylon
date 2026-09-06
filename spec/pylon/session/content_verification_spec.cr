require "file_utils"
require "../../spec_helper"
require "../../../src/pylon/session/local_endpoint"

private alias Bases = Pylon::Wire::Bases
private alias Chunks = Pylon::Wire::Chunks
private alias Map = Pylon::Wire::Checksums::Map
private alias Reader = Pylon::Wire::Reader

private def stale_digest_source(root : String) : {Pylon::Session::LocalEndpoint, Bytes}
  endpoint = local_endpoint(root)
  tree = endpoint.scan(Time.utc.to_unix_ns.to_i64 - 5_000_000_000)

  digest = Fixtures.file!(Fixtures.dig!(tree, "racy.rb")).digest

  File.write(File.join(root, "racy.rb"), "changed after the scan")
  {endpoint, digest}
end

describe "content verification against the advertised digest" do
  it "drops a streamed file that changed after it was scanned" do
    root = File.tempname("pylon-verify-stream")
    Dir.mkdir_p(root)
    File.write(File.join(root, "racy.rb"), "scanned content")

    begin
      endpoint, digest = stale_digest_source(root)

      wire = IO::Memory.new
      source = endpoint.content_source(
        [digest],
        1_u64 * 1024 * 1024,
        Map.new,
        Bases.new,
      )
      source.write(wire)
      wire.rewind

      contents = Chunks.read_contents(Reader.new(wire))
      contents.has_key?(digest).should be_false
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "drops a streamed file that vanished after it was scanned" do
    root = File.tempname("pylon-verify-vanish")
    Dir.mkdir_p(root)
    File.write(File.join(root, "racy.rb"), "scanned content")

    begin
      endpoint = local_endpoint(root)
      tree = endpoint.scan(Time.utc.to_unix_ns.to_i64 - 5_000_000_000)
      digest = Fixtures.file!(Fixtures.dig!(tree, "racy.rb")).digest

      File.delete(File.join(root, "racy.rb"))

      wire = IO::Memory.new
      source = endpoint.content_source(
        [digest],
        1_u64 * 1024 * 1024,
        Map.new,
        Bases.new,
      )
      source.write(wire)
      wire.rewind

      contents = Chunks.read_contents(Reader.new(wire))
      contents.has_key?(digest).should be_false
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "drops a materialised file that changed after it was scanned" do
    root = File.tempname("pylon-verify-materialise")
    Dir.mkdir_p(root)
    File.write(File.join(root, "racy.rb"), "scanned content")

    begin
      endpoint, digest = stale_digest_source(root)

      contents = endpoint.content_source(
        [digest],
        1_u64 * 1024 * 1024,
        Map.new,
        Bases.new,
      ).contents
      contents.has_key?(digest).should be_false
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
