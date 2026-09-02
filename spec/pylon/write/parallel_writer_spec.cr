require "../../spec_helper"
require "../../../src/pylon/write/writer"
require "../../../src/pylon/session/staging"
require "../../../src/pylon/wire/patch"
require "../../../src/pylon/disk"

private FILES = 120

private def build_writer(disk, contents, parallelism = Pylon::Write::Writer::DEFAULT_PARALLELISM)
  Pylon::Write::Writer.new(disk, Pylon::Session::Staging.new(contents, Pylon::Session::Staging::Unrecoverable.new), Pylon::Scan::Cache.new, Time.utc.to_unix_ns.to_i64, parallelism: parallelism)
end

private def bulk_changes : Pylon::Core::Changes
  changes = Pylon::Core::Changes.new

  changes << Pylon::Core::Change.new("nested", nil, Pylon::Core::Directory.new)

  FILES.times do |index|
    content = "content #{index}\n" * (index + 1)
    digest = Digest::SHA256.digest("file#{index}").to_slice
    entry = Pylon::Core::File.new(digest, executable: index.even?)
    path = index < FILES // 2 ? "file#{index}.cr" : "nested/file#{index}.cr"
    changes << Pylon::Core::Change.new(path, nil, entry)
  end

  changes
end

private def staged_contents(changes : Pylon::Core::Changes) : Pylon::Wire::Contents
  contents = Pylon::Wire::Contents.new

  changes.each_with_index do |change, index|
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
      parallel = build_writer(Pylon::Disk.new(parallel_root), contents).write(changes)
      sequential = build_writer(Pylon::Disk.new(sequential_root), contents, 1).write(changes)

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

        File.info(File.join(parallel_root, change.path)).permissions.owner_execute?.should eq(entry.executable?)
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
      outcomes = build_writer(Pylon::Disk.new(root), contents, 24).write(changes)

      outcomes.size.should eq(changes.size)
      outcomes.count(&.applied?).should eq(changes.size)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "creates every directory before the files inside it, whatever ran in parallel" do
    changes = Pylon::Core::Changes.new
    contents = Pylon::Wire::Contents.new

    20.times do |index|
      digest = Digest::SHA256.digest("nested#{index}").to_slice
      contents[digest] = "body #{index}".to_slice
      changes << Pylon::Core::Change.new("d#{index}", nil, Pylon::Core::Directory.new)
      changes << Pylon::Core::Change.new("d#{index}/file.rb", nil, Pylon::Core::File.new(digest))
    end

    root = File.tempname("pylon-parallel-nested")
    Dir.mkdir_p(root)

    begin
      outcomes = build_writer(Pylon::Disk.new(root), contents).write(changes)

      outcomes.count(&.applied?).should eq(changes.size)
      20.times { |index| File.read(File.join(root, "d#{index}", "file.rb")).should eq("body #{index}") }
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "still reports a skip per missing staged content" do
    changes = bulk_changes
    contents = staged_contents(changes)
    missing = changes.compact_map { |change| (entry = change.new).is_a?(Pylon::Core::File) ? entry.digest : nil }.first(5)
    missing.each { |digest| contents.delete(digest) }

    root = File.tempname("pylon-parallel-skip")
    Dir.mkdir_p(root)

    begin
      outcomes = build_writer(Pylon::Disk.new(root), contents).write(changes)

      outcomes.count { |outcome| outcome.skipped.is_a?(Pylon::Write::StagedContentMissing) }.should eq(missing.size)
      outcomes.count(&.applied?).should eq(changes.size - missing.size)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
