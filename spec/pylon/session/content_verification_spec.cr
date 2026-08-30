require "file_utils"
require "../../spec_helper"
require "../../../src/pylon/session/local_endpoint"

private def stale_digest_source(root : String) : {Pylon::Session::LocalEndpoint, Bytes}
  endpoint = Pylon::Session::LocalEndpoint.new(root)
  snapshot = endpoint.scan(Time.utc.to_unix_ns.to_i64 - 5_000_000_000)

  digest = Fixtures.file!(Fixtures.dig!(snapshot.root, "racy.rb")).digest

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
      endpoint.content_source([digest], 1_u64 * 1024 * 1024).write(wire)
      wire.rewind

      contents = Pylon::Wire.read_contents(wire)
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

      contents = endpoint.content_source([digest], 1_u64 * 1024 * 1024).contents
      contents.has_key?(digest).should be_false
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
