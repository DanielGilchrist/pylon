require "../../spec_helper"

require "../../support/unrecoverable"

private alias Change = Pylon::Core::Change
private alias Changes = Pylon::Core::Changes
private alias Contents = Pylon::Wire::Contents
private alias Directory = Pylon::Core::Directory
private alias Disk = Pylon::Disk
private alias Staging = Pylon::Session::Staging
private alias Writer = Pylon::Write::Writer

private FILES = 120

private def build_writer(
  disk : Disk,
  contents : Contents,
  parallelism = Pylon::Write::Writer::DEFAULT_PARALLELISM,
) : Writer(Disk, Staging(Unrecoverable))
  Writer.new(
    disk,
    Staging.new(contents, Unrecoverable.new),
    Pylon::Scan::Cache.new,
    Time.utc.to_unix_ns.to_i64,
    Pylon::Scan::Ignores::NONE,
    parallelism: parallelism,
  )
end

private def bulk_changes : Changes
  changes = Changes.new

  changes << Change.new("nested", nil, Directory.new)

  FILES.times do |index|
    digest = Digest::SHA256.digest("file#{index}").to_slice
    entry = Pylon::Core::File.new(digest, executable: index.even?)
    path = index < FILES // 2 ? "file#{index}.cr" : "nested/file#{index}.cr"
    changes << Change.new(path, nil, entry)
  end

  changes
end

private def staged_contents(changes : Changes) : Contents
  contents = Contents.new

  changes.each do |change|
    entry = change.new
    next unless entry.is_a?(Pylon::Core::File)

    contents[entry.digest] = "content for #{change.path}\n".to_slice
  end

  contents
end

describe "Writer running independent file writes in parallel" do
  it "produces the same outcomes and files as the sequential writer" do
    changes = bulk_changes
    contents = staged_contents(changes)

    parallel_root = File.tempname("pylon-parallel")
    sequential_root = File.tempname("pylon-sequential")
    Dir.mkdir_p(parallel_root)
    Dir.mkdir_p(sequential_root)

    begin
      parallel = build_writer(Disk.new(parallel_root), contents).write(changes)
      sequential = build_writer(Disk.new(sequential_root), contents, 1).write(changes)

      parallel.size.should eq(changes.size)
      parallel.map(&.path).should eq(changes.map(&.path))
      parallel.map(&.path).should eq(sequential.map(&.path))
      parallel.count(&.applied?).should eq(sequential.count(&.applied?))

      changes.each do |change|
        entry = change.new
        next unless entry.is_a?(Pylon::Core::File)

        left = File.read(File.join(parallel_root, change.path))
        right = File.read(File.join(sequential_root, change.path))
        left.should eq(right)

        File.info(File.join(parallel_root, change.path)).permissions.owner_execute?.should eq(
          entry.executable?,
        )
      end
    ensure
      FileUtils.rm_rf(parallel_root)
      FileUtils.rm_rf(sequential_root)
    end
  end

  it "handles worker counts that do not divide the changes evenly" do
    changes = bulk_changes.batch(0, 101)
    contents = staged_contents(changes)

    root = File.tempname("pylon-parallel-uneven")
    Dir.mkdir_p(root)

    begin
      outcomes = build_writer(Disk.new(root), contents, 24).write(changes)

      outcomes.size.should eq(changes.size)
      outcomes.count(&.applied?).should eq(changes.size)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "creates every directory before the files inside it, whatever ran in parallel" do
    changes = Changes.new
    contents = Contents.new

    20.times do |index|
      digest = Digest::SHA256.digest("nested#{index}").to_slice
      contents[digest] = "body #{index}".to_slice
      changes << Change.new("d#{index}", nil, Directory.new)
      changes << Change.new(
        "d#{index}/file.rb",
        nil,
        Pylon::Core::File.new(digest, executable: false),
      )
    end

    root = File.tempname("pylon-parallel-nested")
    Dir.mkdir_p(root)

    begin
      outcomes = build_writer(Disk.new(root), contents).write(changes)

      outcomes.count(&.applied?).should eq(changes.size)
      20.times do |index|
        File.read(File.join(root, "d#{index}", "file.rb")).should eq("body #{index}")
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "still reports a skip per missing staged content" do
    changes = bulk_changes
    contents = staged_contents(changes)
    missing = changes.compact_map do |change|
      entry = change.new
      entry.digest if entry.is_a?(Pylon::Core::File)
    end.first(5)
    missing.each { |digest| contents.delete(digest) }

    root = File.tempname("pylon-parallel-skip")
    Dir.mkdir_p(root)

    begin
      outcomes = build_writer(Disk.new(root), contents).write(changes)

      unrecovered = outcomes.count do |outcome|
        outcome.skipped == Pylon::Write::Skip::StagedContentMissing
      end

      unrecovered.should eq(missing.size)
      outcomes.count(&.applied?).should eq(changes.size - missing.size)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
