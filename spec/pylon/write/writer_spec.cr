require "../../spec_helper"
require "../../support/memory_target"
require "../../../src/pylon/write/writer"

include Pylon::Write

private NOW = 1_000_000_000_000_i64

private def writer(
  target : MemoryTarget,
  staging : MemoryStaging,
  cache : Pylon::Scan::Cache,
) : Writer(MemoryTarget, MemoryStaging)
  Writer.new(target, staging, cache, NOW, Pylon::Scan::Ignores::NONE)
end

private def cache_for(target : MemoryTarget, paths : Enumerable(String)) : Pylon::Scan::Cache
  cache = Pylon::Scan::Cache.new

  paths.each do |path|
    node = target.nodes[path]
    next unless (metadata = target.metadata(path))

    cache[path] = Pylon::Scan::CacheEntry.new(
      metadata,
      Digest::SHA256.digest(node.content),
      freshly_written: false,
    )
  end

  cache
end

describe Pylon::Write::Writer do
  it "creates a file from staged content" do
    target = MemoryTarget.new
    staging = MemoryStaging.new
    digest = staging.add("hello")

    outcomes = writer(target, staging, Pylon::Scan::Cache.new)
      .write(
        Pylon::Core::Changes[Change.new(
          "greeting.txt",
          nil,
          Pylon::Core::File.new(digest, executable: false),
        )],
      )

    outcomes.size.should eq(1)
    outcomes.first.applied?.should be_true
    target.operations.should eq(["write greeting.txt"])
    String.new(target.nodes["greeting.txt"].content).should eq("hello")
  end

  it "creates a whole subtree in one change" do
    target = MemoryTarget.new
    staging = MemoryStaging.new
    digest = staging.add("body")

    subtree = Pylon::Core::Directory.new(
      {"models" => Pylon::Core::Directory.new(
        {"user.rb" => Pylon::Core::File.new(digest, executable: false)},
      )},
    )

    outcome = writer(target, staging, Pylon::Scan::Cache.new)
      .write(Pylon::Core::Changes[Change.new("app", nil, subtree)]).first

    outcome.applied?.should be_true
    target.operations.should eq(["mkdir app", "mkdir app/models", "write app/models/user.rb"])
  end

  it "creates a symlink and reports it as applied" do
    target = MemoryTarget.new

    outcome = writer(target, MemoryStaging.new, Pylon::Scan::Cache.new)
      .write(
        Pylon::Core::Changes[Change.new("link", nil, Pylon::Core::SymbolicLink.new("elsewhere"))],
      ).first

    outcome.applied?.should be_true
    outcome.entry.should eq(Pylon::Core::SymbolicLink.new("elsewhere"))
    target.operations.should eq(["symlink link"])
    target.nodes["link"].target.should eq("elsewhere")
  end

  it "says why a symlink could not be created" do
    target = MemoryTarget.new
    target.writable = false

    outcome = writer(target, MemoryStaging.new, Pylon::Scan::Cache.new)
      .write(
        Pylon::Core::Changes[Change.new("link", nil, Pylon::Core::SymbolicLink.new("elsewhere"))],
      ).first

    outcome.applied?.should be_false
    outcome.skipped.should eq(Pylon::Problem.new("the target is read-only"))
    outcome.entry.should be_nil
  end

  it "refuses to overwrite a file that changed since it was scanned" do
    target = MemoryTarget.new
    original = target.seed_file("notes.txt", "original")
    cache = cache_for(target, ["notes.txt"])

    target.seed_file("notes.txt", "edited by hand", inode: 2_u64, mtime_ns: 9_000_i64)

    staging = MemoryStaging.new
    incoming = staging.add("from the other side")

    outcome = writer(target, staging, cache)
      .write(
        Pylon::Core::Changes[Change.new(
          "notes.txt",
          Pylon::Core::File.new(original, executable: false),
          Pylon::Core::File.new(incoming, executable: false),
        )],
      ).first

    outcome.applied?.should be_false
    outcome.skipped.should eq(Skip::ModificationDetected)
    target.operations.should be_empty
    String.new(target.nodes["notes.txt"].content).should eq("edited by hand")
  end

  it "catches an edit hidden inside the clock granularity window by rehashing" do
    target = MemoryTarget.new
    original = target.seed_file("notes.txt", "original", mtime_ns: NOW)
    cache = cache_for(target, ["notes.txt"])

    target.seed_file("notes.txt", "origiNAL", mtime_ns: NOW)

    staging = MemoryStaging.new
    incoming = staging.add("from the other side")

    outcome = writer(target, staging, cache)
      .write(
        Pylon::Core::Changes[Change.new(
          "notes.txt",
          Pylon::Core::File.new(original, executable: false),
          Pylon::Core::File.new(incoming, executable: false),
        )],
      ).first

    outcome.applied?.should be_false
    outcome.skipped.should eq(Skip::ModificationDetected)
    String.new(target.nodes["notes.txt"].content).should eq("origiNAL")
  end

  it "still overwrites a freshly modified file once a rehash proves it unchanged" do
    target = MemoryTarget.new
    original = target.seed_file("notes.txt", "original", mtime_ns: NOW)
    cache = cache_for(target, ["notes.txt"])

    staging = MemoryStaging.new
    incoming = staging.add("from the other side")

    outcome = writer(target, staging, cache)
      .write(
        Pylon::Core::Changes[Change.new(
          "notes.txt",
          Pylon::Core::File.new(original, executable: false),
          Pylon::Core::File.new(incoming, executable: false),
        )],
      ).first

    outcome.applied?.should be_true
    String.new(target.nodes["notes.txt"].content).should eq("from the other side")
  end

  it "refuses to act without cache evidence" do
    target = MemoryTarget.new
    digest = target.seed_file("notes.txt", "original")
    staging = MemoryStaging.new
    incoming = staging.add("replacement")

    outcome = writer(target, staging, Pylon::Scan::Cache.new)
      .write(
        Pylon::Core::Changes[Change.new(
          "notes.txt",
          Pylon::Core::File.new(digest, executable: false),
          Pylon::Core::File.new(incoming, executable: false),
        )],
      ).first

    outcome.skipped.should eq(Skip::UnknownState)
    target.operations.should be_empty
  end

  it "changes only the mode when the content is identical" do
    target = MemoryTarget.new
    digest = target.seed_file("script.sh", "#!/bin/sh")
    cache = cache_for(target, ["script.sh"])
    staging = MemoryStaging.new

    outcome = writer(target, staging, cache).write(Pylon::Core::Changes[
      Change.new(
        "script.sh",
        Pylon::Core::File.new(digest, executable: false),
        Pylon::Core::File.new(digest, executable: true),
      ),
    ]).first

    outcome.applied?.should be_true
    target.operations.should eq(["chmod script.sh"])
    target.nodes["script.sh"].executable.should be_true
  end

  it "says why a permission change failed instead of pretending content is missing" do
    target = MemoryTarget.new
    digest = target.seed_file("script.sh", "#!/bin/sh")
    cache = cache_for(target, ["script.sh"])
    target.writable = false

    outcome = writer(target, MemoryStaging.new, cache).write(Pylon::Core::Changes[
      Change.new(
        "script.sh",
        Pylon::Core::File.new(digest, executable: false),
        Pylon::Core::File.new(digest, executable: true),
      ),
    ]).first

    outcome.applied?.should be_false
    outcome.skipped.should eq(Pylon::Problem.new("the target is read-only"))
    outcome.entry.should eq(Pylon::Core::File.new(digest, executable: false))
  end

  it "replaces a file with a single write and never clears the path first" do
    target = MemoryTarget.new
    original = target.seed_file("notes.txt", "before")
    cache = cache_for(target, ["notes.txt"])
    staging = MemoryStaging.new
    incoming = staging.add("after")

    outcome = writer(target, staging, cache)
      .write(
        Pylon::Core::Changes[Change.new(
          "notes.txt",
          Pylon::Core::File.new(original, executable: false),
          Pylon::Core::File.new(incoming, executable: false),
        )],
      ).first

    outcome.applied?.should be_true
    target.operations.should eq(["write notes.txt"])
  end

  it "clears the path first when a directory is involved" do
    target = MemoryTarget.new
    target.seed_directory("app")
    digest = target.seed_file("app/user.rb", "x")
    cache = cache_for(target, ["app/user.rb"])
    staging = MemoryStaging.new
    incoming = staging.add("now a file")

    old = Pylon::Core::Directory.new(
      {"user.rb" => Pylon::Core::File.new(digest, executable: false)},
    )
    outcome = writer(target, staging, cache)
      .write(
        Pylon::Core::Changes[Change.new(
          "app",
          old,
          Pylon::Core::File.new(incoming, executable: false),
        )],
      ).first

    outcome.applied?.should be_true
    target.operations.should eq(["remove app", "write app"])
  end

  it "removes a deleted path" do
    target = MemoryTarget.new
    digest = target.seed_file("gone.txt", "bye")
    cache = cache_for(target, ["gone.txt"])

    outcome = writer(target, MemoryStaging.new, cache)
      .write(
        Pylon::Core::Changes[Change.new(
          "gone.txt",
          Pylon::Core::File.new(digest, executable: false),
          nil,
        )],
      ).first

    outcome.applied?.should be_true
    outcome.entry.should be_nil
    target.nodes.has_key?("gone.txt").should be_false
  end

  it "refuses to remove a directory that gained a file since the scan" do
    target = MemoryTarget.new
    target.seed_directory("docs")
    digest = target.seed_file("docs/known.md", "known")
    cache = cache_for(target, ["docs/known.md"])

    target.seed_file("docs/fresh.md", "created after the scan")

    old = Pylon::Core::Directory.new(
      {"known.md" => Pylon::Core::File.new(digest, executable: false)},
    )
    outcome = writer(target, MemoryStaging.new, cache)
      .write(Pylon::Core::Changes[Change.new("docs", old, nil)]).first

    outcome.applied?.should be_false
    outcome.skipped.should eq(Skip::ModificationDetected)
    target.nodes.has_key?("docs/fresh.md").should be_true
  end

  it "refuses to remove a directory holding a file edited since the scan" do
    target = MemoryTarget.new
    target.seed_directory("docs")
    digest = target.seed_file("docs/notes.md", "original")
    cache = cache_for(target, ["docs/notes.md"])

    target.seed_file("docs/notes.md", "edited by hand", inode: 2_u64, mtime_ns: 9_000_i64)

    old = Pylon::Core::Directory.new(
      {"notes.md" => Pylon::Core::File.new(digest, executable: false)},
    )
    outcome = writer(target, MemoryStaging.new, cache)
      .write(Pylon::Core::Changes[Change.new("docs", old, nil)]).first

    outcome.applied?.should be_false
    outcome.skipped.should eq(Skip::ModificationDetected)
    String.new(target.nodes["docs/notes.md"].content).should eq("edited by hand")
  end

  it "refuses to remove a directory that gained a file deep inside a nested directory" do
    target = MemoryTarget.new
    target.seed_directory("docs")
    target.seed_directory("docs/guides")
    digest = target.seed_file("docs/guides/setup.md", "steps")
    cache = cache_for(target, ["docs/guides/setup.md"])

    target.seed_file("docs/guides/fresh.md", "created after the scan")

    old = Pylon::Core::Directory.new({
      "guides" => Pylon::Core::Directory.new(
        {"setup.md" => Pylon::Core::File.new(digest, executable: false)},
      ),
    })
    outcome = writer(target, MemoryStaging.new, cache)
      .write(Pylon::Core::Changes[Change.new("docs", old, nil)]).first

    outcome.applied?.should be_false
    outcome.skipped.should eq(Skip::ModificationDetected)
    target.nodes.has_key?("docs/guides/fresh.md").should be_true
  end

  it "still removes a directory when the only surprise inside is ignored" do
    target = MemoryTarget.new
    target.seed_directory("docs")
    digest = target.seed_file("docs/known.md", "known")
    cache = cache_for(target, ["docs/known.md"])

    target.seed_file("docs/.DS_Store", "junk")

    old = Pylon::Core::Directory.new(
      {"known.md" => Pylon::Core::File.new(digest, executable: false)},
    )
    outcome = writer(target, MemoryStaging.new, cache)
      .write(Pylon::Core::Changes[Change.new("docs", old, nil)]).first

    outcome.applied?.should be_true
    target.nodes.has_key?("docs").should be_false
  end

  it "still removes a directory when a known child already vanished" do
    target = MemoryTarget.new
    target.seed_directory("docs")
    digest = target.seed_file("docs/known.md", "known")
    cache = cache_for(target, ["docs/known.md"])

    target.nodes.delete("docs/known.md")

    old = Pylon::Core::Directory.new(
      {"known.md" => Pylon::Core::File.new(digest, executable: false)},
    )
    outcome = writer(target, MemoryStaging.new, cache)
      .write(Pylon::Core::Changes[Change.new("docs", old, nil)]).first

    outcome.applied?.should be_true
    target.nodes.has_key?("docs").should be_false
  end

  it "removes a case variant before creating its replacement, even in a parallel batch" do
    target = MemoryTarget.new
    staging = MemoryStaging.new
    old_digest = target.seed_file("Readme.md", "content")
    cache = cache_for(target, ["Readme.md"])
    incoming = staging.add("content")

    changes = Pylon::Core::Changes.new
    changes << Change.new("Readme.md", Pylon::Core::File.new(old_digest, executable: false), nil)
    changes << Change.new("README.md", nil, Pylon::Core::File.new(incoming, executable: false))

    20.times do |index|
      digest = staging.add("filler #{index}")
      changes << Change.new(
        "filler#{index}.rb",
        nil,
        Pylon::Core::File.new(digest, executable: false),
      )
    end

    parallel = Writer.new(target, staging, cache, NOW, Pylon::Scan::Ignores::NONE, parallelism: 4)
    outcomes = parallel.write(changes)

    outcomes.count(&.applied?).should eq(changes.size)
    target.operations.index("remove Readme.md").should_not be_nil
    remove_at = target.operations.index("remove Readme.md")
    write_at = target.operations.index("write README.md")
    next if remove_at.nil? || write_at.nil?

    (remove_at < write_at).should be_true
  end

  it "reports what is actually on disk when staged content is missing" do
    target = MemoryTarget.new
    staging = MemoryStaging.new
    missing = Digest::SHA256.digest("never staged".to_slice)

    outcome = writer(target, staging, Pylon::Scan::Cache.new)
      .write(
        Pylon::Core::Changes[Change.new(
          "ghost.txt",
          nil,
          Pylon::Core::File.new(missing, executable: false),
        )],
      ).first

    outcome.applied?.should be_false
    outcome.skipped.should eq(Skip::StagedContentMissing)
    outcome.entry.should be_nil
    target.nodes.has_key?("ghost.txt").should be_false
  end

  it "says why a write failed instead of hiding the reason" do
    target = MemoryTarget.new
    target.writable = false
    staging = MemoryStaging.new
    digest = staging.add("hello")

    outcome = writer(target, staging, Pylon::Scan::Cache.new)
      .write(
        Pylon::Core::Changes[Change.new(
          "greeting.txt",
          nil,
          Pylon::Core::File.new(digest, executable: false),
        )],
      ).first

    outcome.applied?.should be_false
    outcome.skipped.should eq(Pylon::Problem.new("the target is read-only"))
    outcome.entry.should be_nil
  end

  it "says why a deletion failed and keeps the base honest" do
    target = MemoryTarget.new
    staging = MemoryStaging.new
    digest = target.seed_file("stuck", "body")
    cache = cache_for(target, ["stuck"])
    target.writable = false

    outcome = writer(target, staging, cache)
      .write(
        Pylon::Core::Changes[Change.new(
          "stuck",
          Pylon::Core::File.new(digest, executable: false),
          nil,
        )],
      ).first

    outcome.applied?.should be_false
    outcome.skipped.should eq(Pylon::Problem.new("the target is read-only"))
    outcome.entry.should_not be_nil
    target.nodes.has_key?("stuck").should be_true
  end

  it "reports the partially built subtree when a write fails midway" do
    target = MemoryTarget.new
    staging = MemoryStaging.new
    present = staging.add("here")
    absent = Digest::SHA256.digest("absent".to_slice)

    subtree = Pylon::Core::Directory.new({
      "kept.rb" => Pylon::Core::File.new(present, executable: false),
      "lost.rb" => Pylon::Core::File.new(absent, executable: false),
    })

    outcome = writer(target, staging, Pylon::Scan::Cache.new)
      .write(Pylon::Core::Changes[Change.new("app", nil, subtree)]).first

    outcome.applied?.should be_false
    entry = outcome.entry
    next unless entry.is_a?(Pylon::Core::Directory)

    entry.contents.keys.should eq(["kept.rb"])
  end
end

private def seeded_tree(target : MemoryTarget) : {Pylon::Core::Directory, Pylon::Scan::Cache}
  target.seed_directory("lib")
  target.seed_directory("lib/deep")
  a = target.seed_file("lib/a.rb", "a", inode: 11_u64)
  b = target.seed_file("lib/deep/b.rb", "b", inode: 12_u64)
  cache = cache_for(target, ["lib/a.rb", "lib/deep/b.rb"])

  tree = Pylon::Core::Directory.new({
    "a.rb" => Pylon::Core::File.new(a, executable: false),
    "deep" => Pylon::Core::Directory.new({"b.rb" => Pylon::Core::File.new(b, executable: false)}),
  })

  {tree, cache}
end

private def relocate(
  target : MemoryTarget,
  cache : Pylon::Scan::Cache,
  tree : Pylon::Core::Directory,
  staging = MemoryStaging.new,
) : Array(Outcome)
  writer(target, staging, cache).write(
    Pylon::Core::Changes.new,
    [Pylon::Core::Relocation.new("lib", "moved", tree)],
  )
end

describe "relocations" do
  it "moves a directory with a single rename and reports both ends" do
    target = MemoryTarget.new
    tree, cache = seeded_tree(target)

    outcomes = relocate(target, cache, tree)

    target.operations.should eq(["rename lib moved"])
    outcomes.map(&.path).should eq(["lib", "moved"])
    outcomes.all?(&.applied?).should be_true
    outcomes[0].entry.should be_nil
    (outcomes[1].entry == tree).should be_true
    target.nodes.has_key?("moved/deep/b.rb").should be_true
    target.nodes.has_key?("lib").should be_false
  end

  it "moves a single file" do
    target = MemoryTarget.new
    digest = target.seed_file("old.rb", "content", inode: 7_u64)
    cache = cache_for(target, ["old.rb"])

    outcomes = writer(target, MemoryStaging.new, cache)
      .write(
        Pylon::Core::Changes.new,
        [Pylon::Core::Relocation.new(
          "old.rb",
          "new.rb",
          Pylon::Core::File.new(digest, executable: false),
        )],
      )

    target.operations.should eq(["rename old.rb new.rb"])
    outcomes.all?(&.applied?).should be_true
    String.new(target.nodes["new.rb"].content).should eq("content")
  end

  it "refuses to move a directory that lost a file since the scan" do
    target = MemoryTarget.new
    tree, cache = seeded_tree(target)
    target.nodes.delete("lib/deep/b.rb")

    outcomes = relocate(target, cache, tree)

    target.operations.should be_empty
    outcomes.map(&.skipped).should eq([Skip::ModificationDetected, Skip::ModificationDetected])
    (outcomes[0].entry == tree).should be_true
    outcomes[1].entry.should be_nil
  end

  it "refuses to move a directory that gained a file since the scan" do
    target = MemoryTarget.new
    tree, cache = seeded_tree(target)
    target.seed_file("lib/fresh.rb", "created after the scan")

    outcomes = relocate(target, cache, tree)

    target.operations.should be_empty
    outcomes.map(&.skipped).should eq([Skip::ModificationDetected, Skip::ModificationDetected])
  end

  it "refuses to move a directory holding a file edited since the scan" do
    target = MemoryTarget.new
    tree, cache = seeded_tree(target)
    target.seed_file("lib/a.rb", "edited by hand", inode: 99_u64, mtime_ns: 9_000_i64)

    outcomes = relocate(target, cache, tree)

    target.operations.should be_empty
    outcomes.map(&.skipped).should eq([Skip::ModificationDetected, Skip::ModificationDetected])
  end

  it "refuses to move onto a path something else now occupies" do
    target = MemoryTarget.new
    tree, cache = seeded_tree(target)
    target.seed_file("moved", "squatter")

    outcomes = relocate(target, cache, tree)

    target.operations.should be_empty
    outcomes.map(&.skipped).should eq([Skip::ModificationDetected, Skip::ModificationDetected])
  end

  it "refuses to act without cache evidence for the moved files" do
    target = MemoryTarget.new
    tree, _ = seeded_tree(target)

    outcomes = relocate(target, Pylon::Scan::Cache.new, tree)

    target.operations.should be_empty
    outcomes.map(&.skipped).should eq([Skip::UnknownState, Skip::UnknownState])
  end

  it "copies and deletes when the filesystem refuses the rename" do
    target = MemoryTarget.new
    tree, cache = seeded_tree(target)
    target.renamable = false
    staging = MemoryStaging.new
    staging.add("a")
    staging.add("b")

    outcomes = relocate(target, cache, tree, staging)

    target.operations.should eq([
      "mkdir moved",
      "write moved/a.rb",
      "mkdir moved/deep",
      "write moved/deep/b.rb",
      "remove lib",
    ])
    outcomes.map(&.path).should eq(["moved", "moved/a.rb", "moved/deep", "moved/deep/b.rb", "lib"])
    outcomes.all?(&.applied?).should be_true
  end

  it "moves only after every other change in the batch has been written" do
    target = MemoryTarget.new
    tree, cache = seeded_tree(target)
    staging = MemoryStaging.new
    digest = staging.add("fresh")

    writer(target, staging, cache).write(
      Pylon::Core::Changes[Change.new(
        "fresh.rb",
        nil,
        Pylon::Core::File.new(digest, executable: false),
      )],
      [Pylon::Core::Relocation.new("lib", "moved", tree)],
    )

    target.operations.should eq(["write fresh.rb", "rename lib moved"])
  end
end
