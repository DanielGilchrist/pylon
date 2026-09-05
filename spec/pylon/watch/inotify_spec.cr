{% skip_file unless flag?(:linux) %}

require "file_utils"
require "../../spec_helper"
require "../../../src/pylon/watch/inotify"

include Pylon::Watch

private def collect_until(watcher : Inotify, & : Set(String) -> Bool) : Set(String)
  seen = Set(String).new

  10.times do
    case (dirty = watcher.dirty_paths.consume)
    in Everything
      fail("expected per-path events, saw a fresh-instance flush")
    in Touched
      dirty.paths.each { |path| seen << path }
    end

    return seen if yield seen

    select
    when watcher.dirty_paths.signals.receive
    when timeout(2.seconds)
      return seen
    end
  end

  seen
end

describe Pylon::Watch::Inotify do
  it "reports touched paths, nested creations and respects ignores" do
    root = File.tempname("pylon-inotify")
    Dir.mkdir_p(File.join(root, "log"))

    dirty_paths = DirtyPaths.new(Channel(Nil).new(1))
    watcher = Inotify.open(root, ["log"], dirty_paths, brand: Pylon::Brand::DEFAULT)
    watcher.should be_a(Inotify)
    next unless watcher.is_a?(Inotify)

    begin
      File.write(File.join(root, "code.rb"), "puts 1")

      seen = collect_until(watcher, &.includes?("code.rb"))
      seen.includes?("code.rb").should be_true

      Dir.mkdir_p(File.join(root, "nested", "deeper"))
      File.write(File.join(root, "nested", "deeper", "inner.rb"), "puts 2")

      seen = collect_until(watcher, &.includes?("nested/deeper/inner.rb"))
      seen.includes?("nested/deeper/inner.rb").should be_true

      File.write(File.join(root, "log", "noise.log"), "ignored")
      File.write(File.join(root, "sentinel.rb"), "puts 3")

      seen = collect_until(watcher, &.includes?("sentinel.rb"))
      seen.includes?("sentinel.rb").should be_true
      seen.none?(&.starts_with?("log")).should be_true
    ensure
      watcher.close
      FileUtils.rm_rf(root)
    end
  end

  it "notices modification and deletion of a watched file" do
    root = File.tempname("pylon-inotify-edit")
    Dir.mkdir_p(root)
    File.write(File.join(root, "kept.rb"), "before")

    watcher = Inotify.open(
      root,
      Array(String).new,
      DirtyPaths.new(Channel(Nil).new(1)),
      brand: Pylon::Brand::DEFAULT,
    )
    watcher.should be_a(Inotify)
    next unless watcher.is_a?(Inotify)

    begin
      File.write(File.join(root, "kept.rb"), "after")

      collect_until(watcher, &.includes?("kept.rb")).includes?("kept.rb").should be_true

      File.delete(File.join(root, "kept.rb"))

      collect_until(watcher, &.includes?("kept.rb")).includes?("kept.rb").should be_true
    ensure
      watcher.close
      FileUtils.rm_rf(root)
    end
  end

  it "reports the files inside a directory moved into the root" do
    root = File.tempname("pylon-inotify-move")
    staging = File.tempname("pylon-inotify-staging")
    Dir.mkdir_p(root)
    Dir.mkdir_p(File.join(staging, "incoming", "sub"))
    File.write(File.join(staging, "incoming", "top.rb"), "puts 1")
    File.write(File.join(staging, "incoming", "sub", "inner.rb"), "puts 2")

    watcher = Inotify.open(
      root,
      Array(String).new,
      DirtyPaths.new(Channel(Nil).new(1)),
      brand: Pylon::Brand::DEFAULT,
    )
    watcher.should be_a(Inotify)
    next unless watcher.is_a?(Inotify)

    begin
      File.rename(File.join(staging, "incoming"), File.join(root, "incoming"))

      seen = collect_until(watcher, &.includes?("incoming/sub/inner.rb"))
      seen.includes?("incoming/sub/inner.rb").should be_true
      seen.includes?("incoming/top.rb").should be_true
    ensure
      watcher.close
      FileUtils.rm_rf(root)
      FileUtils.rm_rf(staging)
    end
  end

  it "keeps watching a directory created after the watcher started" do
    root = File.tempname("pylon-inotify-late")
    Dir.mkdir_p(root)

    watcher = Inotify.open(
      root,
      Array(String).new,
      DirtyPaths.new(Channel(Nil).new(1)),
      brand: Pylon::Brand::DEFAULT,
    )
    watcher.should be_a(Inotify)
    next unless watcher.is_a?(Inotify)

    begin
      Dir.mkdir(File.join(root, "fresh"))

      collect_until(watcher, &.includes?("fresh")).includes?("fresh").should be_true

      File.write(File.join(root, "fresh", "born.rb"), "puts 1")

      collect_until(watcher, &.includes?("fresh/born.rb")).includes?("fresh/born.rb").should be_true
    ensure
      watcher.close
      FileUtils.rm_rf(root)
    end
  end
end
