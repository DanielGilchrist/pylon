require "file_utils"
require "../../spec_helper"
require "../../../src/pylon/session/checkpoint"

include Pylon::Session

private def in_sandbox(& : String ->)
  root = File.join(Dir.tempdir, "pylon-store-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)

  begin
    yield File.join(root, "state")
  ensure
    FileUtils.rm_rf(root)
  end
end

private def sample_cache : Pylon::Scan::Cache
  cache = Pylon::Scan::Cache.new

  cache["app/user.rb"] = Pylon::Scan::CacheEntry.new(
    Pylon::Scan::Metadata.new(mode: 33188_u32, size: 42_u64, mtime_ns: 1_700_i64, inode: 9_u64),
    "digest-a".to_slice,
  )

  cache
end

describe Pylon::Session::Checkpoint do
  it "round trips an base and both caches" do
    in_sandbox do |path|
      base = Entry.directory({"app" => Entry.directory({"user.rb" => Fixtures.f1})})

      Checkpoint.new(base, sample_cache, Pylon::Scan::Cache.new).save(path).should be_true

      loaded = Checkpoint.load(path).should_not be_nil
      next if loaded.nil?

      Entry.equal?(loaded.base, base).should be_true

      entry = loaded.local_cache["app/user.rb"]
      entry.metadata.inode.should eq(9_u64)
      entry.metadata.mtime_ns.should eq(1_700_i64)
      entry.metadata.size.should eq(42_u64)
      entry.digest.should eq("digest-a".to_slice)
      loaded.remote_cache.should be_empty
    end
  end

  it "round trips an empty state" do
    in_sandbox do |path|
      Checkpoint.new.save(path)

      loaded = Checkpoint.load(path).should_not be_nil
      next if loaded.nil?

      loaded.base.should be_nil
    end
  end

  it "returns nothing for a file that is not a store" do
    in_sandbox do |path|
      File.write(path, "not a pylon state file at all")

      Checkpoint.load(path).should be_nil
    end
  end

  it "returns nothing for a truncated store rather than half a state" do
    in_sandbox do |path|
      Checkpoint.new(Entry.directory({"a" => Fixtures.f1}), sample_cache, sample_cache).save(path)
      bytes = File.read(path).to_slice.dup

      File.write(path, bytes[0, bytes.size // 2])

      Checkpoint.load(path).should be_nil
    end
  end

  it "returns nothing when the format version moves on" do
    in_sandbox do |path|
      Checkpoint.new.save(path)
      bytes = File.read(path).to_slice.dup
      bytes[Checkpoint::MAGIC.bytesize] = 99_u8
      File.write(path, bytes)

      Checkpoint.load(path).should be_nil
    end
  end

  it "leaves no temporary files behind" do
    in_sandbox do |path|
      Checkpoint.new(nil, sample_cache, sample_cache).save(path)

      Dir.children(File.dirname(path)).should eq(["state"])
    end
  end
end
