require "file_utils"
require "../../spec_helper"
require "../../../src/pylon/session/local_endpoint"

include Pylon::Session

private def in_endpoint(files : Hash(String, String), & : LocalEndpoint, Hash(String, Bytes) ->)
  root = File.join(Dir.tempdir, "pylon-endpoint-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)

  digests = {} of String => Bytes
  files.each do |name, content|
    File.write(File.join(root, name), content)
    digests[name] = Digest::SHA256.digest(content).to_slice
  end

  endpoint = LocalEndpoint.new(root)
  endpoint.scan(Time.utc.to_unix_ns.to_i64)

  begin
    yield endpoint, digests
  ensure
    FileUtils.rm_rf(root)
  end
end

describe Pylon::Session::LocalEndpoint do
  it "stops adding content once a batch reaches the transfer budget" do
    in_endpoint({"a.rb" => "x" * 10, "b.rb" => "y" * 10, "c.rb" => "z" * 10}) do |endpoint, digests|
      offered = endpoint.content_source([digests["a.rb"], digests["b.rb"], digests["c.rb"]], 15_u64)

      offered.digests.should eq(Set{digests["a.rb"]})
    end
  end

  it "always offers the first file even when it alone is over the budget" do
    in_endpoint({"big.rb" => "x" * 100}) do |endpoint, digests|
      offered = endpoint.content_source([digests["big.rb"]], 1_u64)

      offered.digests.should eq(Set{digests["big.rb"]})
    end
  end

  it "fills the budget exactly when the sizes allow it" do
    in_endpoint({"a.rb" => "x" * 10, "b.rb" => "y" * 10} of String => String) do |endpoint, digests|
      offered = endpoint.content_source([digests["a.rb"], digests["b.rb"]], 20_u64)

      offered.digests.should eq(Set{digests["a.rb"], digests["b.rb"]})
    end
  end

  it "skips digests it does not have rather than failing" do
    in_endpoint({"a.rb" => "here"}) do |endpoint, digests|
      unknown = Digest::SHA256.digest("never scanned").to_slice

      offered = endpoint.content_source([unknown, digests["a.rb"]], 1_000_u64)

      offered.digests.should eq(Set{digests["a.rb"]})
    end
  end
end
