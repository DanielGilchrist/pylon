require "../../spec_helper"
require "../../../src/pylon/write/writer"
require "../../../src/pylon/session/staging"
require "../../../src/pylon/wire/contents"
require "../../../src/pylon/disk"

private FILES = 120

private def bulk_changes : Array(Pylon::Core::Change)
  changes = [] of Pylon::Core::Change

  changes << Pylon::Core::Change.new("nested", nil, Pylon::Core::Entry.directory)

  FILES.times do |index|
    content = "content #{index}\n" * (index + 1)
    digest = Digest::SHA256.digest("file#{index}").to_slice
    entry = Pylon::Core::Entry.file(digest, executable: index.even?)
    path = index < FILES // 2 ? "file#{index}.cr" : "nested/file#{index}.cr"
    changes << Pylon::Core::Change.new(path, nil, entry)
  end

  changes
end

private def staged_contents(changes : Array(Pylon::Core::Change)) : Pylon::Wire::Contents
  contents = Pylon::Wire::Contents.new

  changes.each_with_index do |change, index|
    entry = change.new
    next if entry.nil?

    if (digest = entry.digest)
      contents[digest] = "content for #{change.path}\n".to_slice
    end
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
      parallel = Pylon::Write::Writer.new(
        Pylon::Disk.new(parallel_root),
        Pylon::Session::Staging.new(contents),
        Pylon::Scan::Cache.new,
      ).write(changes)

      sequential = Pylon::Write::Writer.new(
        Pylon::Disk.new(sequential_root),
        Pylon::Session::Staging.new(contents),
        Pylon::Scan::Cache.new,
        parallelism: 1,
      ).write(changes)

      parallel.size.should eq(changes.size)
      parallel.map(&.path).should eq(changes.map(&.path))
      parallel.map(&.path).should eq(sequential.map(&.path))
      parallel.count(&.applied?).should eq(sequential.count(&.applied?))

      changes.each do |change|
        entry = change.new
        next if entry.nil? || !entry.kind.file?

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
    changes = bulk_changes.first(101)
    contents = staged_contents(changes)

    root = File.tempname("pylon-parallel-uneven")
    Dir.mkdir_p(root)

    begin
      outcomes = Pylon::Write::Writer.new(
        Pylon::Disk.new(root),
        Pylon::Session::Staging.new(contents),
        Pylon::Scan::Cache.new,
        parallelism: 24,
      ).write(changes)

      outcomes.size.should eq(changes.size)
      outcomes.count(&.applied?).should eq(changes.size)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "still reports a skip per missing staged content" do
    changes = bulk_changes
    contents = staged_contents(changes)
    missing = changes.compact_map { |change| change.new.try(&.digest) }.first(5)
    missing.each { |digest| contents.delete(digest) }

    root = File.tempname("pylon-parallel-skip")
    Dir.mkdir_p(root)

    begin
      outcomes = Pylon::Write::Writer.new(
        Pylon::Disk.new(root),
        Pylon::Session::Staging.new(contents),
        Pylon::Scan::Cache.new,
      ).write(changes)

      outcomes.count { |outcome| outcome.skipped.try(&.staged_content_missing?) }.should eq(missing.size)
      outcomes.count(&.applied?).should eq(changes.size - missing.size)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
