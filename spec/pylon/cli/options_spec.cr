require "../../spec_helper"
require "../../../src/pylon/cli/sync"
require "../../../src/pylon/cli/local"

private def parse_sync(extra : Array(String) = [] of String) : Pylon::CLI::Sync
  parsed = Pylon::CLI::Sync.parse(["./here", "user@host:/there"] + extra)
  raise "the sync command did not parse: #{parsed.inspect}" unless parsed.is_a?(Pylon::CLI::Sync)

  parsed
end

private def parse_local(extra : Array(String) = [] of String) : Pylon::CLI::Local
  parsed = Pylon::CLI::Local.parse(["./one", "./two"] + extra)
  raise "the local command did not parse: #{parsed.inspect}" unless parsed.is_a?(Pylon::CLI::Local)

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
    parsed.remote_command.should eq(Pylon::CLI::DEFAULT_REMOTE_COMMAND)
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

describe Pylon::CLI::Local do
  it "syncs once, writing and explaining nothing extra, by default" do
    parsed = parse_local

    parsed.watch?.should be_false
    parsed.dry_run?.should be_false
    parsed.verbose?.should be_false
    parsed.state.should be_nil
  end

  it "turns on watching, dry runs and verbosity from their short flags" do
    parsed = parse_local(["-w", "-n", "-v"])

    parsed.watch?.should be_true
    parsed.dry_run?.should be_true
    parsed.verbose?.should be_true
  end
end
