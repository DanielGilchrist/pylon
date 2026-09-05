require "../../spec_helper"
require "../../support/memory_filesystem"
require "../../../src/pylon/discard"
require "../../../src/pylon/scan/scanner"

private def scan_with(tally : Pylon::Scan::Tally, files : Hash(String, String)) : Nil
  Pylon::Scan::Scanner.new(
    MemoryFilesystem.build(files),
    Pylon::Scan::Cache.new,
    1_000_000_000_i64,
    Pylon::Scan::Ignores::NONE,
    baseline: nil,
    recheck: Set(String).new,
    tally: tally, keeper: Pylon::Discard.new,
  ).scan
end

describe Pylon::Scan::Tally do
  it "counts the files a scan saw and the bytes it hashed" do
    tally = Pylon::Scan::Tally.new

    scan_with(tally, {"a.rb" => "12345", "b/c.rb" => "123"})

    tally.files.should eq(2)
    tally.hashed_bytes.should eq(8)
  end

  it "is not finished until someone says so, then starts over on reset" do
    tally = Pylon::Scan::Tally.new

    tally.finished?.should be_false
    tally.finish
    tally.finished?.should be_true

    tally.reset
    tally.finished?.should be_false
    tally.files.should eq(0)
    tally.hashed_bytes.should eq(0)
  end
end
