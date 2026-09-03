require "../../spec_helper"
require "../../../src/pylon/cli/sync"
require "../../../src/pylon/cli/serve"

private def parse_sync(extra : Array(String) = Array(String).new) : Pylon::CLI::Sync
  parsed = Pylon::CLI::Sync.parse(["./here", "user@host:/there"] + extra)
  raise "the sync command did not parse: #{parsed.inspect}" unless parsed.is_a?(Pylon::CLI::Sync)

  parsed
end

private def parse_serve(extra : Array(String) = Array(String).new) : Pylon::CLI::Serve
  parsed = Pylon::CLI::Serve.parse(["./here"] + extra)
  raise "the serve command did not parse: #{parsed.inspect}" unless parsed.is_a?(Pylon::CLI::Serve)

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
    parsed.brand.should eq(Pylon::Brand::DEFAULT)
  end

  it "goes by another brand when given one" do
    parse_sync(["--brand", "Test Sync"]).brand.should eq(Pylon::Brand.new("Test Sync"))
  end

  it "refuses a blank brand rather than printing nothing in its place" do
    parsed = Pylon::CLI::Sync.parse(["./here", "user@host:/there", "--brand", "  "])

    parsed.should be_a(Kebab::Error::InvalidValue)
    parsed.to_s.should contain(%("  " isn't a valid brand for "--brand" (it is blank)))
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

describe Pylon::CLI::Serve do
  it "goes by pylon unless told otherwise" do
    parse_serve.brand.should eq(Pylon::Brand::DEFAULT)
    parse_serve(["--brand", "Test Sync"]).brand.should eq(Pylon::Brand.new("Test Sync"))
  end
end
