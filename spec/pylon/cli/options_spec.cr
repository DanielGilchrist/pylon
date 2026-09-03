require "../../spec_helper"
require "../../../src/pylon/cli/sync"

private def parse_sync(extra : Array(String) = Array(String).new) : Pylon::CLI::Sync
  parsed = Pylon::CLI::Sync.parse(["./here", "user@host:/there"] + extra)
  raise "the sync command did not parse: #{parsed.inspect}" unless parsed.is_a?(Pylon::CLI::Sync)

  parsed
end

describe Pylon::CLI::Sync do
  it "syncs once, writing and explaining nothing extra, by default" do
    parsed = parse_sync

    parsed.watch?.should be_false
    parsed.dry_run?.should be_false
    parsed.verbose?.should be_false
    parsed.ignore.should be_empty
    parsed.state.should be_nil
    parsed.remote_command.should eq(Pylon::CLI::Sync::DEFAULT_REMOTE_COMMAND)
    parsed.compression.should eq(Pylon::CLI::Sync::DEFAULT_COMPRESSION)
  end

  it "compresses harder than a local sync because the link, not the CPU, is the bottleneck" do
    Pylon::CLI::Sync::DEFAULT_COMPRESSION.should be > Pylon::Compress::Zstd::DEFAULT_LEVEL
    parse_sync(["--compression", "1"]).compression.should eq(1)
  end

  it "keeps the given directories" do
    parsed = parse_sync

    parsed.local.should eq("./here")
    parsed.remote.should eq("user@host:/there")
  end

  it "turns on watching, dry runs and verbosity from their short flags" do
    parsed = parse_sync(["-w", "-n", "-v"])

    parsed.watch?.should be_true
    parsed.dry_run?.should be_true
    parsed.verbose?.should be_true
  end

  it "collects every repeated ignore and preference" do
    parsed = parse_sync([
      "--ignore", "node_modules", "--ignore", ".git",
      "--prefer-local", "*.log", "--prefer-remote", ".",
    ])

    parsed.ignore.should eq(["node_modules", ".git"])
    parsed.prefer_local.should eq(["*.log"])
    parsed.prefer_remote.should eq(["."])
  end
end
