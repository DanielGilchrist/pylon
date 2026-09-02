require "../../spec_helper"
require "../../../src/pylon/write/guard"

include Pylon::Write

private MTIME  = 1_700_000_000_000_000_000_i64
private DIGEST = "d1".to_slice
private OTHER  = "d2".to_slice

private def metadata(
  mode : UInt32 = (LibC::S_IFREG | 0o644).to_u32,
  size : UInt64 = 100_u64,
  mtime_ns : Int64 = MTIME,
  inode : UInt64 = 7_u64,
) : Pylon::Scan::Metadata
  Pylon::Scan::Metadata.new(mode: mode, size: size, mtime_ns: mtime_ns, inode: inode)
end

private def observed_file(**overrides) : Pylon::Scan::ObservedFile
  Pylon::Scan::ObservedFile.new(metadata(**overrides))
end

private def cached(digest : Bytes = DIGEST, **overrides) : Pylon::Scan::CacheEntry
  Pylon::Scan::CacheEntry.new(metadata(**overrides), digest)
end

private NOW = MTIME + 1_000_000_000_i64 * 10

private def check(expected : Pylon::Core::Entry?, cached : Pylon::Scan::CacheEntry?, observed : Pylon::Scan::Observed | Problem | Nil) : Verdict
  Guard.check(expected, cached, observed, NOW)
end

describe Pylon::Write::Guard do
  it "permits creating a path that does not exist" do
    check(nil, nil, nil).should eq(Verdict::Proceed)
  end

  it "refuses to create over something that appeared" do
    check(nil, nil, observed_file).should eq(Verdict::ModificationDetected)
  end

  it "refuses to act when the expected file vanished" do
    check(Pylon::Core::File.new(DIGEST), cached, nil).should eq(Verdict::ModificationDetected)
  end

  it "permits replacing a file that still matches the cache and the expected digest" do
    check(Pylon::Core::File.new(DIGEST), cached, observed_file).should eq(Verdict::Proceed)
  end

  it "refuses without cache evidence, rather than assuming safety" do
    check(Pylon::Core::File.new(DIGEST), nil, observed_file).should eq(Verdict::UnknownState)
  end

  it "refuses when the file changed since it was scanned" do
    check(Pylon::Core::File.new(DIGEST), cached, observed_file(size: 101_u64)).should eq(Verdict::ModificationDetected)
    check(Pylon::Core::File.new(DIGEST), cached, observed_file(mtime_ns: MTIME + 1)).should eq(Verdict::ModificationDetected)
    check(Pylon::Core::File.new(DIGEST), cached, observed_file(inode: 8_u64)).should eq(Verdict::ModificationDetected)
  end

  it "cannot conclude anything about a file modified within the clock granularity window" do
    fresh = observed_file(mtime_ns: NOW)
    entry = Pylon::Scan::CacheEntry.new(metadata(mtime_ns: NOW), DIGEST)

    check(Pylon::Core::File.new(DIGEST), entry, fresh).should eq(Verdict::Inconclusive)
  end

  it "cannot conclude anything from a digest that was recorded inside the granularity window" do
    entry = Pylon::Scan::CacheEntry.new(metadata, DIGEST, provisional: true)

    check(Pylon::Core::File.new(DIGEST), entry, observed_file).should eq(Verdict::Inconclusive)
  end

  it "refuses when only the permissions changed" do
    executable = observed_file(mode: (LibC::S_IFREG | 0o755).to_u32)

    check(Pylon::Core::File.new(DIGEST), cached, executable).should eq(Verdict::ModificationDetected)
  end

  it "refuses when the cached digest disagrees with what we planned against" do
    check(Pylon::Core::File.new(OTHER), cached, observed_file).should eq(Verdict::ModificationDetected)
  end

  it "refuses when a file was replaced by a directory" do
    check(Pylon::Core::File.new(DIGEST), cached, Pylon::Scan::ObservedDirectory.new).should eq(Verdict::ModificationDetected)
  end

  it "checks kind for directories and target for symlinks" do
    check(Pylon::Core::Directory.new, nil, Pylon::Scan::ObservedDirectory.new).should eq(Verdict::Proceed)
    check(Pylon::Core::Directory.new, nil, Pylon::Scan::ObservedLink.new("t")).should eq(Verdict::ModificationDetected)
    check(Pylon::Core::SymbolicLink.new("t"), nil, Pylon::Scan::ObservedLink.new("t")).should eq(Verdict::Proceed)
    check(Pylon::Core::SymbolicLink.new("t"), nil, Pylon::Scan::ObservedDirectory.new).should eq(Verdict::ModificationDetected)
  end

  it "refuses to overwrite a symlink that was pointed somewhere else" do
    check(Pylon::Core::SymbolicLink.new("intended"), nil, Pylon::Scan::ObservedLink.new("retargeted")).should eq(Verdict::ModificationDetected)
  end

  it "never proceeds against unsyncable expectations" do
    check(Pylon::Core::Untracked.new, nil, observed_file).should eq(Verdict::UnknownState)
    check(Pylon::Core::Problematic.new("x"), nil, observed_file).should eq(Verdict::UnknownState)
  end
end
