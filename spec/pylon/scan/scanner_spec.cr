require "../../spec_helper"
require "../../support/memory_filesystem"
require "../../../src/pylon/scan/scanner"

include Pylon::Scan

private NOW = 1_000_000_000_000_i64

private def scan(
  filesystem : MemoryFilesystem,
  cache : Cache = Cache.new,
  ignores : Ignores = Ignores::NONE,
) : Snapshot
  Scanner.new(filesystem, cache, NOW, ignores, parallelism: 1).scan
end

private def sample : MemoryFilesystem
  MemoryFilesystem.build({
    "app/models/user.rb" => "class User; end",
    "app/models/pay.rb"  => "class Pay; end",
    "README.md"          => "hello",
  })
end

describe Pylon::Scan::Scanner do
  it "builds a tree mirroring the filesystem" do
    root = scan(sample).root.should_not be_nil
    next if root.nil?

    root.directory?.should be_true
    root.contents.keys.sort!.should eq(["README.md", "app"])
    root.contents["app"].contents["models"].contents.keys.sort!.should eq(["pay.rb", "user.rb"])
  end

  it "hashes every file on a cold scan" do
    filesystem = sample
    scan(filesystem)

    filesystem.reads.sort!.should eq(["README.md", "app/models/pay.rb", "app/models/user.rb"])
  end

  it "reuses cached digests instead of rehashing" do
    filesystem = sample
    warm = scan(filesystem).cache

    rescanned = MemoryFilesystem.new(filesystem.@nodes)
    Scanner.new(rescanned, warm, NOW, parallelism: 1).scan

    rescanned.reads.should be_empty
  end

  it "rehashes only the file whose inode changed" do
    filesystem = sample
    warm = scan(filesystem).cache

    changed = filesystem.with("README.md", content: "goodbye", inode: 99_u64)
    Scanner.new(changed, warm, NOW, parallelism: 1).scan

    changed.reads.should eq(["README.md"])
  end

  it "rehashes a file written inside the granularity window" do
    filesystem = sample
    warm = scan(filesystem).cache

    racy = filesystem.with("README.md", mtime_ns: NOW)
    Scanner.new(racy, warm, NOW, parallelism: 1).scan

    racy.reads.should eq(["README.md"])
  end

  it "records the executable bit without rehashing the content" do
    filesystem = sample
    warm = scan(filesystem).cache

    executable = filesystem.with("README.md", executable: true)
    snapshot = Scanner.new(executable, warm, NOW, parallelism: 1).scan
    root = snapshot.root.should_not be_nil
    next if root.nil?

    root.contents["README.md"].executable?.should be_true
    executable.reads.should be_empty
  end

  it "marks ignored paths untracked and never descends into them" do
    filesystem = sample
    snapshot = scan(filesystem, ignores: Ignores.new(["app"]))
    root = snapshot.root.should_not be_nil
    next if root.nil?

    root.contents["app"].untracked?.should be_true
    filesystem.reads.should eq(["README.md"])
  end

  it "marks an unreadable file problematic rather than failing the scan" do
    filesystem = sample.with("README.md", readable: false)
    root = scan(filesystem).root.should_not be_nil
    next if root.nil?

    root.contents["README.md"].problematic?.should be_true
    root.contents["app"].directory?.should be_true
  end

  it "produces a tree the reconciler treats as settled against itself" do
    snapshot = scan(sample)

    Reconciler.reconcile(snapshot.root, snapshot.root, snapshot.root, SyncMode::TwoWaySafe)
      .empty?.should be_true
  end
end

describe Pylon::Scan::Ignores do
  it "ignores a path and everything beneath it" do
    ignores = Ignores.new(["node_modules", "vendor/bundle"])

    ignores.ignore?("node_modules").should be_true
    ignores.ignore?("node_modules/react/index.js").should be_true
    ignores.ignore?("vendor/bundle/ruby/gem.rb").should be_true
    ignores.ignore?("vendor/assets/app.js").should be_false
    ignores.ignore?("app/node_modules_helper.rb").should be_false
    ignores.ignore?("").should be_false
  end
end
