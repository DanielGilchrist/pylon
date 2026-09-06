require "../../spec_helper"

private alias CacheEntry = Pylon::Scan::CacheEntry
private alias Directory = Pylon::Core::Directory
private alias Guard = Pylon::Write::Guard
private alias Metadata = Pylon::Scan::Metadata
private alias ObservedDirectory = Pylon::Scan::ObservedDirectory
private alias ObservedFile = Pylon::Scan::ObservedFile
private alias ObservedLink = Pylon::Scan::ObservedLink
private alias SymbolicLink = Pylon::Core::SymbolicLink
private alias Verdict = Pylon::Write::Verdict
private MTIME  = 1_700_000_000_000_000_000_i64
private DIGEST = "d1".to_slice
private OTHER  = "d2".to_slice

private def metadata(
  mode : UInt32 = (LibC::S_IFREG | 0o644).to_u32,
  size : UInt64 = 100_u64,
  mtime_ns : Int64 = MTIME,
  inode : UInt64 = 7_u64,
) : Metadata
  Metadata.new(mode: mode, size: size, mtime_ns: mtime_ns, inode: inode)
end

private def observed_file(**overrides) : ObservedFile
  ObservedFile.new(metadata(**overrides))
end

private def cached(digest : Bytes = DIGEST, **overrides) : CacheEntry
  CacheEntry.new(metadata(**overrides), digest, freshly_written: false)
end

private NOW = MTIME + 1_000_000_000_i64 * 10

private def check(
  expected : Pylon::Core::Entry?,
  cached : CacheEntry?,
  observed : Pylon::Scan::Observed | Pylon::Problem | Nil,
) : Pylon::Write::Verdict
  Guard.check(expected, cached, observed, NOW)
end

describe Guard do
  it "permits creating a path that does not exist" do
    check(nil, nil, nil).should eq(Verdict::Proceed)
  end

  it "refuses to create over something that appeared" do
    check(nil, nil, observed_file).should eq(Verdict::ModificationDetected)
  end

  it "refuses to act when the expected file vanished" do
    check(Pylon::Core::File.new(DIGEST, executable: false), cached, nil).should eq(
      Verdict::ModificationDetected,
    )
  end

  it "permits replacing a file that still matches the cache and the expected digest" do
    check(Pylon::Core::File.new(DIGEST, executable: false), cached, observed_file).should eq(
      Verdict::Proceed,
    )
  end

  it "refuses without cache evidence, rather than assuming safety" do
    check(Pylon::Core::File.new(DIGEST, executable: false), nil, observed_file).should eq(
      Verdict::UnknownState,
    )
  end

  it "refuses when the file changed since it was scanned" do
    file = Pylon::Core::File.new(DIGEST, executable: false)

    check(file, cached, observed_file(size: 101_u64)).should eq(Verdict::ModificationDetected)
    check(file, cached, observed_file(mtime_ns: MTIME + 1)).should eq(Verdict::ModificationDetected)
    check(file, cached, observed_file(inode: 8_u64)).should eq(Verdict::ModificationDetected)
  end

  it "cannot conclude anything about a file modified within the clock granularity window" do
    fresh = observed_file(mtime_ns: NOW)
    entry = CacheEntry.new(metadata(mtime_ns: NOW), DIGEST, freshly_written: false)

    check(Pylon::Core::File.new(DIGEST, executable: false), entry, fresh).should eq(
      Verdict::Inconclusive,
    )
  end

  it "cannot conclude anything from a digest that was recorded inside the granularity window" do
    entry = CacheEntry.new(metadata, DIGEST, freshly_written: true)

    check(Pylon::Core::File.new(DIGEST, executable: false), entry, observed_file).should eq(
      Verdict::Inconclusive,
    )
  end

  it "refuses when only the permissions changed" do
    executable = observed_file(mode: (LibC::S_IFREG | 0o755).to_u32)

    check(Pylon::Core::File.new(DIGEST, executable: false), cached, executable).should eq(
      Verdict::ModificationDetected,
    )
  end

  it "refuses when the cached digest disagrees with what we planned against" do
    check(Pylon::Core::File.new(OTHER, executable: false), cached, observed_file).should eq(
      Verdict::ModificationDetected,
    )
  end

  it "refuses when a file was replaced by a directory" do
    file = Pylon::Core::File.new(DIGEST, executable: false)

    check(file, cached, ObservedDirectory.new).should eq(Verdict::ModificationDetected)
  end

  it "checks kind for directories and target for symlinks" do
    check(Directory.new, nil, ObservedDirectory.new).should eq(
      Verdict::Proceed,
    )
    check(Directory.new, nil, ObservedLink.new("t")).should eq(
      Verdict::ModificationDetected,
    )
    check(SymbolicLink.new("t"), nil, ObservedLink.new("t")).should eq(
      Verdict::Proceed,
    )
    check(SymbolicLink.new("t"), nil, ObservedDirectory.new).should eq(
      Verdict::ModificationDetected,
    )
  end

  it "refuses to overwrite a symlink that was pointed somewhere else" do
    link = SymbolicLink.new("intended")
    retargeted = ObservedLink.new("retargeted")

    check(link, nil, retargeted).should eq(Verdict::ModificationDetected)
  end

  it "never proceeds against unsyncable expectations" do
    check(Pylon::Core::Untracked.new, nil, observed_file).should eq(Verdict::UnknownState)
    check(Pylon::Core::Problematic.new("x"), nil, observed_file).should eq(Verdict::UnknownState)
  end
end
