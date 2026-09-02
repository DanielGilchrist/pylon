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

    directory = Fixtures.directory!(root)
    directory.contents.keys.sort!.should eq(["README.md", "app"])
    Fixtures.directory!(Fixtures.dig!(root, "app", "models")).contents.keys.sort!.should eq(["pay.rb", "user.rb"])
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

  it "distrusts a digest that was recorded inside the granularity window" do
    filesystem = sample.with("README.md", mtime_ns: NOW)
    warm = scan(filesystem).cache

    edited = filesystem.with("README.md", content: "howdy")
    later = NOW + Scanner::DEFAULT_GRANULARITY_NS * 10
    snapshot = Scanner.new(edited, warm, later, parallelism: 1).scan

    edited.reads.should eq(["README.md"])
    root = snapshot.root.should_not be_nil
    next if root.nil?

    Fixtures.file!(Fixtures.dig!(root, "README.md")).digest
      .should eq(Digest::SHA256.digest("howdy"))
  end

  it "records the executable bit without rehashing the content" do
    filesystem = sample
    warm = scan(filesystem).cache

    executable = filesystem.with("README.md", executable: true)
    snapshot = Scanner.new(executable, warm, NOW, parallelism: 1).scan
    root = snapshot.root.should_not be_nil
    next if root.nil?

    Fixtures.file!(Fixtures.dig!(root, "README.md")).executable?.should be_true
    executable.reads.should be_empty
  end

  it "marks ignored paths untracked and never descends into them" do
    filesystem = sample
    snapshot = scan(filesystem, ignores: Ignores.new(["app"]))
    root = snapshot.root.should_not be_nil
    next if root.nil?

    Fixtures.dig!(root, "app").is_a?(Pylon::Core::Untracked).should be_true
    filesystem.reads.should eq(["README.md"])
  end

  it "keeps a path whose metadata cannot be examined as problematic rather than absent" do
    filesystem = sample.with("app/models/user.rb", statable: false)
    root = scan(filesystem).root

    flagged = Fixtures.problem!(Fixtures.dig!(root, "app", "models", "user.rb"))
    flagged.problem.should contain("EACCES")
  end

  it "marks an unreadable file problematic rather than failing the scan" do
    filesystem = sample.with("README.md", readable: false)
    root = scan(filesystem).root.should_not be_nil
    next if root.nil?

    Fixtures.dig!(root, "README.md").is_a?(Pylon::Core::Problematic).should be_true
    Fixtures.dig!(root, "app").is_a?(Pylon::Core::Directory).should be_true
  end

  it "produces a tree the reconciler treats as settled against itself" do
    snapshot = scan(sample)

    reconciliation = Reconciler.reconcile(snapshot.root, snapshot.root, snapshot.root)

    reconciliation.base_changes.should be_empty
    reconciliation.local_changes.should be_empty
    reconciliation.remote_changes.should be_empty
    reconciliation.conflicts.should be_empty
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

  it "ignores editor scratch files everywhere without any configured patterns" do
    ignores = Ignores::NONE

    ignores.ignore?(".leave_balance.rb.swp").should be_true
    ignores.ignore?("app/models/.leave_balance.rb.swp").should be_true
    ignores.ignore?("app/models/.leave_balance.rb.swo").should be_true
    ignores.ignore?("docs/.DS_Store").should be_true
    ignores.ignore?("app/#scratch.rb#").should be_true

    ignores.ignore?("app/models/leave_balance.rb").should be_false
    ignores.ignore?("recordings/session.swp").should be_false
    ignores.ignore?("app/models/swap.rb").should be_false
    ignores.ignore?("#").should be_false
  end
end

describe "accelerated scanning" do
  it "does no filesystem work at all when nothing is dirty" do
    filesystem = sample
    first = scan(filesystem)

    quiet = MemoryFilesystem.new(filesystem.@nodes)
    second = Scanner.new(quiet, first.cache, NOW, parallelism: 1, baseline: first.root).scan

    quiet.reads.should be_empty
    (second.root == first.root).should be_true
    second.cache.size.should eq(first.cache.size)
  end

  it "rebuilds only the dirty subtree" do
    filesystem = sample
    first = scan(filesystem)

    changed = filesystem.with("app/models/pay.rb", content: "class Pay2; end", inode: 77_u64)
    second = Scanner.new(
      changed, first.cache, NOW,
      parallelism: 1,
      baseline: first.root,
      recheck: Set{"app/models/pay.rb"},
    ).scan

    changed.reads.should eq(["app/models/pay.rb"])

    root = second.root.should_not be_nil
    next if root.nil?

    Fixtures.file!(Fixtures.dig!(root, "README.md")).digest.should eq(Fixtures.file!(Fixtures.dig!(first.root, "README.md")).digest)
    Fixtures.directory!(Fixtures.dig!(root, "app", "models")).contents.keys.sort!.should eq(["pay.rb", "user.rb"])
  end

  it "carries cache entries forward for untouched subtrees" do
    filesystem = sample
    first = scan(filesystem)

    changed = filesystem.with("README.md", content: "new", inode: 88_u64)
    second = Scanner.new(
      changed, first.cache, NOW,
      parallelism: 1,
      baseline: first.root,
      recheck: Set{"README.md"},
    ).scan

    second.cache.keys.sort!.should eq(["README.md", "app/models/pay.rb", "app/models/user.rb"])
    second.cache["app/models/user.rb"].digest.should eq(first.cache["app/models/user.rb"].digest)
  end

  it "notices a file that appeared inside a dirty directory" do
    filesystem = sample
    first = scan(filesystem)

    added = MemoryFilesystem.build({
      "app/models/user.rb" => "class User; end",
      "app/models/pay.rb"  => "class Pay; end",
      "app/models/new.rb"  => "class New; end",
      "README.md"          => "hello",
    })

    second = Scanner.new(
      added, first.cache, NOW,
      parallelism: 1,
      baseline: first.root,
      recheck: Set{"app/models/new.rb"},
    ).scan

    root = second.root.should_not be_nil
    next if root.nil?

    Fixtures.directory!(Fixtures.dig!(root, "app", "models")).contents.keys.sort!.should eq(["new.rb", "pay.rb", "user.rb"])
  end

  it "notices a deletion inside a dirty directory" do
    filesystem = sample
    first = scan(filesystem)

    remaining = MemoryFilesystem.build({
      "app/models/user.rb" => "class User; end",
      "README.md"          => "hello",
    })

    second = Scanner.new(
      remaining, first.cache, NOW,
      parallelism: 1,
      baseline: first.root,
      recheck: Set{"app/models/pay.rb"},
    ).scan

    root = second.root.should_not be_nil
    next if root.nil?

    Fixtures.directory!(Fixtures.dig!(root, "app", "models")).contents.keys.should eq(["user.rb"])
  end
end
