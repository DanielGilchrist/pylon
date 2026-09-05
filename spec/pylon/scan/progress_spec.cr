require "../../spec_helper"
require "../../support/memory_filesystem"
require "../../../src/pylon/discard"
require "../../../src/pylon/scan/scanner"

private def scan_with(scanned : Pylon::Progress, files : Hash(String, String)) : Nil
  Pylon::Scan::Scanner.new(
    MemoryFilesystem.build(files),
    Pylon::Scan::Cache.new,
    1_000_000_000_i64,
    Pylon::Scan::Ignores::NONE,
    baseline: nil,
    recheck: Set(String).new,
    scanned: scanned, keeper: Pylon::Discard.new,
  ).scan
end

describe Pylon::Progress do
  it "counts the files a scan saw and the bytes it hashed" do
    progress = Pylon::Progress.new

    scan_with(progress, {"a.rb" => "12345", "b/c.rb" => "123"})

    progress.files.should eq(2)
    progress.bytes.should eq(8)
  end

  it "is not finished until someone says so, then starts over on reset" do
    progress = Pylon::Progress.new

    progress.finished?.should be_false
    progress.finish
    progress.finished?.should be_true

    progress.reset
    progress.finished?.should be_false
    progress.files.should eq(0)
    progress.bytes.should eq(0)
  end
end
