require "../../spec_helper"
require "../../../src/pylon/scan/cache_entry"

include Pylon::Scan

private BASE_MTIME  = 1_700_000_000_000_000_000_i64
private GRANULARITY =             1_000_000_000_i64
private DIGEST      = "cached".to_slice

private def metadata(
  mode : UInt32 = (LibC::S_IFREG | 0o644).to_u32,
  size : UInt64 = 100_u64,
  mtime_ns : Int64 = BASE_MTIME,
  inode : UInt64 = 42_u64,
) : Metadata
  Metadata.new(mode: mode, size: size, mtime_ns: mtime_ns, inode: inode)
end

private NOW = BASE_MTIME + GRANULARITY * 10

describe Pylon::Scan::Metadata do
  it "maps stat mode onto an entry kind" do
    metadata(mode: (LibC::S_IFREG | 0o644).to_u32).kind.should eq(Pylon::Scan::Metadata::Kind::File)
    metadata(mode: (LibC::S_IFDIR | 0o755).to_u32).kind.should eq(Pylon::Scan::Metadata::Kind::Directory)
    metadata(mode: (LibC::S_IFLNK | 0o777).to_u32).kind.should eq(Pylon::Scan::Metadata::Kind::SymbolicLink)
    metadata(mode: (LibC::S_IFIFO | 0o644).to_u32).kind.should eq(Pylon::Scan::Metadata::Kind::Untracked)
  end

  it "reads the executable bit" do
    metadata(mode: (LibC::S_IFREG | 0o644).to_u32).executable?.should be_false
    metadata(mode: (LibC::S_IFREG | 0o755).to_u32).executable?.should be_true
  end

  it "treats a permission-only change as reusable content but not a reusable entry" do
    readable = metadata(mode: (LibC::S_IFREG | 0o644).to_u32)
    executable = metadata(mode: (LibC::S_IFREG | 0o755).to_u32)

    readable.same_content?(executable).should be_true
    readable.reusable?(executable).should be_false
  end

  it "detects a change in each component of the cache key" do
    base = metadata

    base.reusable?(metadata).should be_true
    base.reusable?(metadata(size: 101_u64)).should be_false
    base.reusable?(metadata(mtime_ns: BASE_MTIME + 1)).should be_false
    base.reusable?(metadata(inode: 43_u64)).should be_false
    base.reusable?(metadata(mode: (LibC::S_IFDIR | 0o644).to_u32)).should be_false
  end

  it "treats a file written inside the clock granularity window as racy" do
    metadata(mtime_ns: NOW).racy?(NOW, GRANULARITY).should be_true
    metadata(mtime_ns: NOW - GRANULARITY + 1).racy?(NOW, GRANULARITY).should be_true
    metadata(mtime_ns: NOW - GRANULARITY).racy?(NOW, GRANULARITY).should be_false
  end
end

describe Pylon::Scan::CacheEntry do
  it "reuses a digest when nothing observable changed" do
    entry = CacheEntry.new(metadata, DIGEST)

    entry.reuse(metadata, NOW, GRANULARITY).should eq(DIGEST)
  end

  it "refuses to reuse a digest for a file inside the granularity window" do
    racy = metadata(mtime_ns: NOW)
    entry = CacheEntry.new(racy, DIGEST)

    entry.reuse(racy, NOW, GRANULARITY).should be_nil
  end

  it "refuses to reuse a digest that was recorded inside the granularity window" do
    entry = CacheEntry.new(metadata, DIGEST, provisional: true)

    entry.reuse(metadata, NOW, GRANULARITY).should be_nil
  end

  it "refuses to reuse a digest when an editor rewrote the file via rename" do
    entry = CacheEntry.new(metadata, DIGEST)

    entry.reuse(metadata(inode: 43_u64), NOW, GRANULARITY).should be_nil
  end
end

describe "Pylon::Scan::Metadata.of" do
  it "reads real inode, size and mode from the filesystem" do
    path = File.join(Dir.tempdir, "pylon-metadata-#{Random.rand(UInt32)}")
    File.write(path, "hello")

    begin
      observed = Metadata.of(path)
      observed.is_a?(Metadata).should be_true
      next unless observed.is_a?(Metadata)

      observed.kind.should eq(Pylon::Scan::Metadata::Kind::File)
      observed.size.should eq(5_u64)
      observed.inode.should_not eq(0_u64)
      observed.executable?.should be_false

      File.chmod(path, 0o755)
      changed = Metadata.of(path)
      changed.executable?.should be_true if changed.is_a?(Metadata)
      changed.is_a?(Metadata).should be_true
    ensure
      File.delete?(path)
    end
  end

  it "returns nil for a path that does not exist" do
    Metadata.of(File.join(Dir.tempdir, "pylon-missing-#{Random.rand(UInt32)}")).should be_nil
  end
end
