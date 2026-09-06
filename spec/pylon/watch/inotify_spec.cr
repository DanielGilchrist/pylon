require "../../spec_helper"

Pylon::Platform.skip_file_unless :linux

private DEFAULT = Pylon::Brand::DEFAULT
private alias DirtyPaths = Pylon::Watch::DirtyPaths
private alias Inotify = Pylon::Watch::Inotify

private def collect_until(watcher : Inotify, & : Set(String) -> Bool) : Set(String)
  seen = Set(String).new

  await(watcher.dirty_paths.signals, for: "a signal from the watcher") do
    case (dirty = watcher.dirty_paths.consume)
    in Pylon::Watch::Everything
      fail("expected per-path events, saw a fresh-instance flush")
    in Pylon::Watch::Touched
      dirty.paths.each { |path| seen << path }
    end

    yield seen
  end

  seen
end

describe Inotify do
  it "reports touched paths, nested creations and respects ignores" do
    Sandbox.open do |root|
      root.directory("log")

      dirty_paths = DirtyPaths.new(Channel(Nil).new(1))
      watcher = Inotify.open(root.root, ["log"], dirty_paths, brand: DEFAULT)
      watcher.should be_a(Inotify)
      next unless watcher.is_a?(Inotify)

      begin
        root.write("code.rb", "puts 1")

        seen = collect_until(watcher, &.includes?("code.rb"))
        seen.includes?("code.rb").should be_true

        root.write("nested/deeper/inner.rb", "puts 2")

        seen = collect_until(watcher, &.includes?("nested/deeper/inner.rb"))
        seen.includes?("nested/deeper/inner.rb").should be_true

        root.write("log/noise.log", "ignored")
        root.write("sentinel.rb", "puts 3")

        seen = collect_until(watcher, &.includes?("sentinel.rb"))
        seen.includes?("sentinel.rb").should be_true
        seen.none?(&.starts_with?("log")).should be_true
      ensure
        watcher.close
      end
    end
  end

  it "notices modification and deletion of a watched file" do
    Sandbox.open do |root|
      root.write("kept.rb", "before")

      watcher = Inotify.open(
        root.root,
        Array(String).new,
        DirtyPaths.new(Channel(Nil).new(1)),
        brand: DEFAULT,
      )
      watcher.should be_a(Inotify)
      next unless watcher.is_a?(Inotify)

      begin
        root.write("kept.rb", "after")

        collect_until(watcher, &.includes?("kept.rb")).includes?("kept.rb").should be_true

        root.remove("kept.rb")

        collect_until(watcher, &.includes?("kept.rb")).includes?("kept.rb").should be_true
      ensure
        watcher.close
      end
    end
  end

  it "reports the files inside a directory moved into the root" do
    Sandbox.open do |sandbox|
      root = sandbox.directory("root")
      staging = sandbox.directory("staging")
      staging.write("incoming/top.rb", "puts 1")
      staging.write("incoming/sub/inner.rb", "puts 2")

      watcher = Inotify.open(
        root.root,
        Array(String).new,
        DirtyPaths.new(Channel(Nil).new(1)),
        brand: DEFAULT,
      )
      watcher.should be_a(Inotify)
      next unless watcher.is_a?(Inotify)

      begin
        File.rename(staging.path("incoming"), root.path("incoming"))

        seen = collect_until(watcher, &.includes?("incoming/sub/inner.rb"))
        seen.includes?("incoming/sub/inner.rb").should be_true
        seen.includes?("incoming/top.rb").should be_true
      ensure
        watcher.close
      end
    end
  end

  it "keeps watching a directory created after the watcher started" do
    Sandbox.open do |root|
      watcher = Inotify.open(
        root.root,
        Array(String).new,
        DirtyPaths.new(Channel(Nil).new(1)),
        brand: DEFAULT,
      )
      watcher.should be_a(Inotify)
      next unless watcher.is_a?(Inotify)

      begin
        root.directory("fresh")

        collect_until(watcher, &.includes?("fresh")).includes?("fresh").should be_true

        root.write("fresh/born.rb", "puts 1")

        seen = collect_until(watcher, &.includes?("fresh/born.rb"))
        seen.includes?("fresh/born.rb").should be_true
      ensure
        watcher.close
      end
    end
  end
end
