require "../../spec_helper"

private alias Bases = Pylon::Wire::Bases
private alias Chunks = Pylon::Wire::Chunks
private alias Map = Pylon::Wire::Checksums::Map
private alias Reader = Pylon::Wire::Reader

private def stale_digest_source(root : Sandbox) : {Pylon::Session::LocalEndpoint, Bytes}
  endpoint = local_endpoint(root)
  tree = endpoint.scan(Time.utc.to_unix_ns.to_i64 - 5_000_000_000)

  digest = Fixtures.file!(Fixtures.dig!(tree, "racy.rb")).digest

  root.write("racy.rb", "changed after the scan")
  {endpoint, digest}
end

describe "content verification against the advertised digest" do
  it "drops a streamed file that changed after it was scanned" do
    Sandbox.open do |sandbox|
      root = sandbox.directory("root")
      root.write("racy.rb", "scanned content")

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
    end
  end

  it "drops a streamed file that vanished after it was scanned" do
    Sandbox.open do |sandbox|
      root = sandbox.directory("root")
      root.write("racy.rb", "scanned content")

      endpoint = local_endpoint(root)
      tree = endpoint.scan(Time.utc.to_unix_ns.to_i64 - 5_000_000_000)
      digest = Fixtures.file!(Fixtures.dig!(tree, "racy.rb")).digest

      root.remove("racy.rb")

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
    end
  end

  it "drops a materialised file that changed after it was scanned" do
    Sandbox.open do |sandbox|
      root = sandbox.directory("root")
      root.write("racy.rb", "scanned content")

      endpoint, digest = stale_digest_source(root)

      contents = endpoint.content_source(
        [digest],
        1_u64 * 1024 * 1024,
        Map.new,
        Bases.new,
      ).contents
      contents.has_key?(digest).should be_false
    end
  end
end
