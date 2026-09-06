require "../../spec_helper"

private alias Cache = Pylon::Scan::Cache
private alias Checkpoint = Pylon::Session::Checkpoint
private alias Directory = Pylon::Core::Directory
private alias Problem = Pylon::Problem

private def in_sandbox(& : String ->) : Nil
  Sandbox.open { |root| yield root.path("state") }
end

private def sample_cache : Cache
  cache = Cache.new

  cache.store("app/user.rb", Pylon::Scan::CacheEntry.new(
    Pylon::Scan::Metadata.new(mode: 33188_u32, size: 42_u64, mtime_ns: 1_700_i64, inode: 9_u64),
    Digest::SHA256.digest("digest-a"),
    freshly_written: false,
  ))

  cache
end

describe Checkpoint do
  it "round trips an base and both caches" do
    in_sandbox do |path|
      base = Directory.new(
        {"app" => Directory.new({"user.rb" => Fixtures.f1})},
      )

      Checkpoint.new(base, sample_cache, nil).save(path).should be_nil

      loaded = Checkpoint.load(path)
      loaded.should be_a(Checkpoint)
      next unless loaded.is_a?(Checkpoint)

      (loaded.base == base).should be_true

      entry = loaded.local_cache["app/user.rb"]
      entry.metadata.inode.should eq(9_u64)
      entry.metadata.mtime_ns.should eq(1_700_i64)
      entry.metadata.size.should eq(42_u64)
      entry.digest.should eq(Digest::SHA256.digest("digest-a"))
      loaded.shared_tree.should be_nil
    end
  end

  it "round trips an empty state" do
    in_sandbox do |path|
      Checkpoint.new.save(path)

      loaded = Checkpoint.load(path)
      loaded.should be_a(Checkpoint)
      next unless loaded.is_a?(Checkpoint)

      loaded.base.should be_nil
    end
  end

  it "reports a missing state file as absent" do
    in_sandbox do |path|
      Checkpoint.load(path).should be_a(Pylon::Missing)
    end
  end

  it "says why a file that is not a store was ignored" do
    in_sandbox do |path|
      File.write(path, "not a pylon state file at all")

      loaded = Checkpoint.load(path)
      loaded.should be_a(Problem)
      next unless loaded.is_a?(Problem)

      loaded.reason.should eq("not a sync state file")
    end
  end

  it "reports a truncated store as damaged rather than half a state" do
    in_sandbox do |path|
      Checkpoint.new(Directory.new({"a" => Fixtures.f1}), sample_cache, nil).save(path)
      bytes = File.read(path).to_slice.dup

      File.write(path, bytes[0, bytes.size // 2])

      Checkpoint.load(path).should be_a(Problem)
    end
  end

  it "reports a state file from another version as damaged" do
    in_sandbox do |path|
      Checkpoint.new.save(path)
      bytes = File.read(path).to_slice.dup
      bytes[Pylon::Session::Checkpoint::MAGIC.bytesize] = 99_u8
      File.write(path, bytes)

      loaded = Checkpoint.load(path)
      loaded.should be_a(Problem)
      next unless loaded.is_a?(Problem)

      loaded.reason.should eq("written by a different version")
    end
  end

  it "leaves no temporary files behind" do
    in_sandbox do |path|
      Checkpoint.new(nil, sample_cache, nil).save(path)

      Dir.children(File.dirname(path)).should eq(["state"])
    end
  end
end
