require "../../spec_helper"
require "../../../src/pylon/write/guard"

include Pylon::Write

private MTIME  = 1_700_000_000_000_000_000_i64
private DIGEST = "d1".to_slice
private OTHER  = "d2".to_slice

private def observed(
  mode : UInt32 = (LibC::S_IFREG | 0o644).to_u32,
  size : UInt64 = 100_u64,
  mtime_ns : Int64 = MTIME,
  inode : UInt64 = 7_u64,
) : Pylon::Scan::Metadata
  Pylon::Scan::Metadata.new(mode: mode, size: size, mtime_ns: mtime_ns, inode: inode)
end

private def cached(digest : Bytes = DIGEST, **overrides) : Pylon::Scan::CacheEntry
  Pylon::Scan::CacheEntry.new(observed(**overrides), digest)
end

describe Pylon::Write::Guard do
  it "permits creating a path that does not exist" do
    Guard.check(nil, nil, nil).should eq(Verdict::Proceed)
  end

  it "refuses to create over something that appeared" do
    Guard.check(nil, nil, observed).should eq(Verdict::ModificationDetected)
  end

  it "refuses to act when the expected file vanished" do
    Guard.check(Pylon::Core::File.new(DIGEST), cached, nil).should eq(Verdict::ModificationDetected)
  end

  it "permits replacing a file that still matches the cache and the expected digest" do
    Guard.check(Pylon::Core::File.new(DIGEST), cached, observed).should eq(Verdict::Proceed)
  end

  it "refuses without cache evidence, rather than assuming safety" do
    Guard.check(Pylon::Core::File.new(DIGEST), nil, observed).should eq(Verdict::UnknownState)
  end

  it "refuses when the file changed since it was scanned" do
    Guard.check(Pylon::Core::File.new(DIGEST), cached, observed(size: 101_u64)).should eq(Verdict::ModificationDetected)
    Guard.check(Pylon::Core::File.new(DIGEST), cached, observed(mtime_ns: MTIME + 1)).should eq(Verdict::ModificationDetected)
    Guard.check(Pylon::Core::File.new(DIGEST), cached, observed(inode: 8_u64)).should eq(Verdict::ModificationDetected)
  end

  it "refuses when only the permissions changed" do
    executable = observed(mode: (LibC::S_IFREG | 0o755).to_u32)

    Guard.check(Pylon::Core::File.new(DIGEST), cached, executable).should eq(Verdict::ModificationDetected)
  end

  it "refuses when the cached digest disagrees with what we planned against" do
    Guard.check(Pylon::Core::File.new(OTHER), cached, observed).should eq(Verdict::ModificationDetected)
  end

  it "refuses when a file was replaced by a directory" do
    directory = observed(mode: (LibC::S_IFDIR | 0o755).to_u32)

    Guard.check(Pylon::Core::File.new(DIGEST), cached, directory).should eq(Verdict::ModificationDetected)
  end

  it "checks kind alone for directories and symlinks" do
    directory = observed(mode: (LibC::S_IFDIR | 0o755).to_u32)
    link = observed(mode: (LibC::S_IFLNK | 0o777).to_u32)

    Guard.check(Pylon::Core::Directory.new, nil, directory).should eq(Verdict::Proceed)
    Guard.check(Pylon::Core::Directory.new, nil, link).should eq(Verdict::ModificationDetected)
    Guard.check(Pylon::Core::SymbolicLink.new("t"), nil, link).should eq(Verdict::Proceed)
    Guard.check(Pylon::Core::SymbolicLink.new("t"), nil, directory).should eq(Verdict::ModificationDetected)
  end

  it "never proceeds against unsynchronizable expectations" do
    Guard.check(Pylon::Core::Untracked.new, nil, observed).should eq(Verdict::UnknownState)
    Guard.check(Pylon::Core::Problematic.new("x"), nil, observed).should eq(Verdict::UnknownState)
  end
end
