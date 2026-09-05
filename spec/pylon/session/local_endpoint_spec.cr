require "file_utils"
require "../../spec_helper"
require "../../../src/pylon/session/local_endpoint"

include Pylon::Session

private def in_endpoint(
  files : Hash(String, String),
  & : LocalEndpoint, Hash(String, Bytes) ->
) : Nil
  root = File.join(Dir.tempdir, "pylon-endpoint-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)

  digests = Hash(String, Bytes).new
  files.each do |name, content|
    File.write(File.join(root, name), content)
    digests[name] = Digest::SHA256.digest(content).to_slice
  end

  endpoint = local_endpoint(root)
  endpoint.scan(Time.utc.to_unix_ns.to_i64)

  begin
    yield endpoint, digests
  ensure
    FileUtils.rm_rf(root)
  end
end

private SHARED = "x" * 2048

describe "resolving a patch base" do
  it "reads the base from the file being patched when another holder of the digest has changed" do
    in_endpoint({"a.bin" => SHARED, "b.bin" => SHARED}) do |endpoint, digests|
      File.write(File.join(endpoint.root, "a.bin"), "rewritten already")

      String.new(endpoint.base_content(digests["b.bin"], "b.bin") || Bytes.empty).should eq(SHARED)
    end
  end

  it "reads the base from the file being patched whichever holder the digest index chose" do
    in_endpoint({"a.bin" => SHARED, "b.bin" => SHARED}) do |endpoint, digests|
      File.write(File.join(endpoint.root, "b.bin"), "rewritten already")

      String.new(endpoint.base_content(digests["a.bin"], "a.bin") || Bytes.empty).should eq(SHARED)
    end
  end
end

describe Pylon::Session::LocalEndpoint do
  it "stops adding content once a batch reaches the transfer budget" do
    in_endpoint({"a.rb" => "x" * 10, "b.rb" => "y" * 10, "c.rb" => "z" * 10}) do |endpoint, digests|
      offered = endpoint.content_source(
        [digests["a.rb"], digests["b.rb"], digests["c.rb"]],
        15_u64,
        Pylon::Wire::Delta::Signatures.new,
        Pylon::Wire::Prefixed::Bases.new,
      )

      offered.digests.should eq(Set{digests["a.rb"]})
    end
  end

  it "always offers the first file even when it alone is over the budget" do
    in_endpoint({"big.rb" => "x" * 100}) do |endpoint, digests|
      offered = endpoint.content_source(
        [digests["big.rb"]],
        1_u64,
        Pylon::Wire::Delta::Signatures.new,
        Pylon::Wire::Prefixed::Bases.new,
      )

      offered.digests.should eq(Set{digests["big.rb"]})
    end
  end

  it "fills the budget exactly when the sizes allow it" do
    in_endpoint({"a.rb" => "x" * 10, "b.rb" => "y" * 10} of String => String) do |endpoint, digests|
      offered = endpoint.content_source(
        [digests["a.rb"], digests["b.rb"]],
        20_u64,
        Pylon::Wire::Delta::Signatures.new,
        Pylon::Wire::Prefixed::Bases.new,
      )

      offered.digests.should eq(Set{digests["a.rb"], digests["b.rb"]})
    end
  end

  it "skips digests it does not have rather than failing" do
    in_endpoint({"a.rb" => "here"}) do |endpoint, digests|
      unknown = Digest::SHA256.digest("never scanned").to_slice

      offered = endpoint.content_source(
        [unknown, digests["a.rb"]],
        1_000_u64,
        Pylon::Wire::Delta::Signatures.new,
        Pylon::Wire::Prefixed::Bases.new,
      )

      offered.digests.should eq(Set{digests["a.rb"]})
    end
  end

  it "writes a file from its own disk when the content arrived without bytes" do
    in_endpoint({"a.rb" => "shared body"}) do |endpoint, digests|
      changes = Pylon::Core::Changes[Change.new(
        "copy.rb",
        nil,
        Pylon::Core::File.new(digests["a.rb"], executable: false),
      )]

      outcomes = endpoint.write(
        changes,
        Pylon::Wire::ContentSource::Materialised.new(Pylon::Wire::Contents.new),
      )

      outcomes.size.should eq(1)
      outcomes[0].applied?.should be_true
      File.read(File.join(endpoint.root, "copy.rb")).should eq("shared body")
    end
  end

  it "answers a signature for a base large enough to be worth a delta" do
    body = "def item end\n" * 1000

    in_endpoint({"a.rb" => body}) do |endpoint, digests|
      wanted = Digest::SHA256.digest("the edited version").to_slice

      found = endpoint.signatures(
        [Pylon::Wire::Message::SignaturesRequest::Pair.new(wanted, digests["a.rb"])],
      )

      found[wanted]?.try(&.base).should eq(digests["a.rb"])
    end
  end

  it "skips signatures for bases too small to be worth a delta" do
    in_endpoint({"a.rb" => "tiny"}) do |endpoint, digests|
      wanted = Digest::SHA256.digest("the edited version").to_slice

      found = endpoint.signatures(
        [Pylon::Wire::Message::SignaturesRequest::Pair.new(wanted, digests["a.rb"])],
      )

      found.should be_empty
    end
  end

  it "refuses recovered content whose bytes no longer match the digest" do
    in_endpoint({"a.rb" => "original"}) do |endpoint, digests|
      File.write(File.join(endpoint.root, "a.rb"), "mutated")
      changes = Pylon::Core::Changes[Change.new(
        "copy.rb",
        nil,
        Pylon::Core::File.new(digests["a.rb"], executable: false),
      )]

      outcomes = endpoint.write(
        changes,
        Pylon::Wire::ContentSource::Materialised.new(Pylon::Wire::Contents.new),
      )

      outcomes.size.should eq(1)
      outcomes[0].applied?.should be_false
      File.exists?(File.join(endpoint.root, "copy.rb")).should be_false
    end
  end
end
