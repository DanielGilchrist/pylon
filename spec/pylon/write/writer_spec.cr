require "../../spec_helper"
require "../../support/memory_target"
require "../../../src/pylon/write/writer"

include Pylon::Write

private def cache_for(target : MemoryTarget, paths : Enumerable(String)) : Pylon::Scan::Cache
  cache = Pylon::Scan::Cache.new

  paths.each do |path|
    node = target.nodes[path]
    metadata = target.metadata(path).not_nil!
    cache[path] = Pylon::Scan::CacheEntry.new(metadata, Digest::SHA256.digest(node.content))
  end

  cache
end

describe Pylon::Write::Writer do
  it "creates a file from staged content" do
    target = MemoryTarget.new
    staging = MemoryStaging.new
    digest = staging.add("hello")

    outcomes = Writer.new(target, staging, Pylon::Scan::Cache.new)
      .write([Change.new("greeting.txt", nil, Entry.file(digest))])

    outcomes.size.should eq(1)
    outcomes.first.applied?.should be_true
    target.operations.should eq(["write greeting.txt"])
    String.new(target.nodes["greeting.txt"].content).should eq("hello")
  end

  it "creates a whole subtree in one change" do
    target = MemoryTarget.new
    staging = MemoryStaging.new
    digest = staging.add("body")

    subtree = Entry.directory({"models" => Entry.directory({"user.rb" => Entry.file(digest)})})

    outcome = Writer.new(target, staging, Pylon::Scan::Cache.new)
      .write([Change.new("app", nil, subtree)]).first

    outcome.applied?.should be_true
    target.operations.should eq(["mkdir app", "mkdir app/models", "write app/models/user.rb"])
  end

  it "refuses to overwrite a file that changed since it was scanned" do
    target = MemoryTarget.new
    original = target.seed_file("notes.txt", "original")
    cache = cache_for(target, ["notes.txt"])

    target.seed_file("notes.txt", "edited by hand", inode: 2_u64, mtime_ns: 9_000_i64)

    staging = MemoryStaging.new
    incoming = staging.add("from the other side")

    outcome = Writer.new(target, staging, cache)
      .write([Change.new("notes.txt", Entry.file(original), Entry.file(incoming))]).first

    outcome.applied?.should be_false
    outcome.skipped.should eq(Skipped::ModificationDetected)
    target.operations.should be_empty
    String.new(target.nodes["notes.txt"].content).should eq("edited by hand")
  end

  it "refuses to act without cache evidence" do
    target = MemoryTarget.new
    digest = target.seed_file("notes.txt", "original")
    staging = MemoryStaging.new
    incoming = staging.add("replacement")

    outcome = Writer.new(target, staging, Pylon::Scan::Cache.new)
      .write([Change.new("notes.txt", Entry.file(digest), Entry.file(incoming))]).first

    outcome.skipped.should eq(Skipped::UnknownState)
    target.operations.should be_empty
  end

  it "changes only the mode when the content is identical" do
    target = MemoryTarget.new
    digest = target.seed_file("script.sh", "#!/bin/sh")
    cache = cache_for(target, ["script.sh"])
    staging = MemoryStaging.new

    outcome = Writer.new(target, staging, cache).write([
      Change.new("script.sh", Entry.file(digest), Entry.file(digest, executable: true)),
    ]).first

    outcome.applied?.should be_true
    target.operations.should eq(["chmod script.sh"])
    target.nodes["script.sh"].executable.should be_true
  end

  it "replaces a file with a single write and never clears the path first" do
    target = MemoryTarget.new
    original = target.seed_file("notes.txt", "before")
    cache = cache_for(target, ["notes.txt"])
    staging = MemoryStaging.new
    incoming = staging.add("after")

    outcome = Writer.new(target, staging, cache)
      .write([Change.new("notes.txt", Entry.file(original), Entry.file(incoming))]).first

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

    old = Entry.directory({"user.rb" => Entry.file(digest)})
    outcome = Writer.new(target, staging, cache)
      .write([Change.new("app", old, Entry.file(incoming))]).first

    outcome.applied?.should be_true
    target.operations.should eq(["remove app", "write app"])
  end

  it "removes a deleted path" do
    target = MemoryTarget.new
    digest = target.seed_file("gone.txt", "bye")
    cache = cache_for(target, ["gone.txt"])

    outcome = Writer.new(target, MemoryStaging.new, cache)
      .write([Change.new("gone.txt", Entry.file(digest), nil)]).first

    outcome.applied?.should be_true
    outcome.entry.should be_nil
    target.nodes.has_key?("gone.txt").should be_false
  end

  it "reports what is actually on disk when staged content is missing" do
    target = MemoryTarget.new
    staging = MemoryStaging.new
    missing = Digest::SHA256.digest("never staged".to_slice)

    outcome = Writer.new(target, staging, Pylon::Scan::Cache.new)
      .write([Change.new("ghost.txt", nil, Entry.file(missing))]).first

    outcome.applied?.should be_false
    outcome.skipped.should eq(Skipped::StagedContentMissing)
    outcome.entry.should be_nil
    target.nodes.has_key?("ghost.txt").should be_false
  end

  it "says why a write failed instead of hiding the reason" do
    target = MemoryTarget.new
    target.writable = false
    staging = MemoryStaging.new
    digest = staging.add("hello")

    outcome = Writer.new(target, staging, Pylon::Scan::Cache.new)
      .write([Change.new("greeting.txt", nil, Entry.file(digest))]).first

    outcome.applied?.should be_false
    outcome.skipped.should eq(Skipped::WriteFailed)
    outcome.problem.should eq("the target is read-only")
    outcome.entry.should be_nil
  end

  it "says why a deletion failed and keeps the base honest" do
    target = MemoryTarget.new
    staging = MemoryStaging.new
    digest = target.seed_file("stuck", "body")
    cache = cache_for(target, ["stuck"])
    target.writable = false

    outcome = Writer.new(target, staging, cache)
      .write([Change.new("stuck", Entry.file(digest), nil)]).first

    outcome.applied?.should be_false
    outcome.skipped.should eq(Skipped::WriteFailed)
    outcome.problem.should eq("the target is read-only")
    outcome.entry.should_not be_nil
    target.nodes.has_key?("stuck").should be_true
  end

  it "reports the partially built subtree when a write fails midway" do
    target = MemoryTarget.new
    staging = MemoryStaging.new
    present = staging.add("here")
    absent = Digest::SHA256.digest("absent".to_slice)

    subtree = Entry.directory({
      "kept.rb" => Entry.file(present),
      "lost.rb" => Entry.file(absent),
    })

    outcome = Writer.new(target, staging, Pylon::Scan::Cache.new)
      .write([Change.new("app", nil, subtree)]).first

    outcome.applied?.should be_false
    entry = outcome.entry.should_not be_nil
    next if entry.nil?

    entry.contents.keys.should eq(["kept.rb"])
  end
end
