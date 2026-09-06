require "../../spec_helper"

Pylon::Platform.skip_file_unless :macos

require "file_utils"

private alias DirtyPaths = Pylon::Watch::DirtyPaths
private alias Everything = Pylon::Watch::Everything
private alias FSEvents = Pylon::Watch::FSEvents
private alias Touched = Pylon::Watch::Touched
private alias Dirty = Pylon::Watch::Dirty

private def consume_within(watcher : FSEvents, seconds : Float64, & : Dirty -> Bool) : Bool
  deadline = Time.instant + seconds.seconds

  while Time.instant < deadline
    return true if yield watcher.dirty_paths.consume

    sleep(50.milliseconds)
  end

  false
end

describe FSEvents do
  it "reports touched paths, nested creations and respects ignores" do
    root = File.tempname("pylon-fsevents")
    Dir.mkdir_p(File.join(root, "log"))

    watcher = FSEvents.open(root, ["log"], DirtyPaths.new(Channel(Nil).new(1)))
    watcher.should be_a(FSEvents)
    next unless watcher.is_a?(FSEvents)

    begin
      sleep(200.milliseconds)
      File.write(File.join(root, "code.rb"), "puts 1")

      seen = consume_within(watcher, 5.0) do |dirty|
        dirty.is_a?(Everything) || (dirty.is_a?(Touched) && dirty.paths.includes?("code.rb"))
      end
      seen.should be_true

      Dir.mkdir_p(File.join(root, "nested", "deeper"))
      File.write(File.join(root, "nested", "deeper", "inner.rb"), "puts 2")

      seen = consume_within(watcher, 5.0) do |dirty|
        next true if dirty.is_a?(Everything)

        dirty.is_a?(Touched) && dirty.paths.any?(&.starts_with?("nested"))
      end
      seen.should be_true

      File.write(File.join(root, "log", "noise.log"), "ignored")
      sleep(400.milliseconds)

      leftover = watcher.dirty_paths.consume
      case leftover
      in Everything
        fail("expected per-path events, saw a fresh-instance flush")
      in Touched
        leftover.paths.none?(&.starts_with?("log")).should be_true
      end
    ensure
      watcher.close
      FileUtils.rm_rf(root)
    end
  end

  it "reports the files inside a directory moved into the root" do
    root = File.tempname("pylon-fsevents-move")
    staging = File.tempname("pylon-fsevents-staging")
    Dir.mkdir_p(root)
    Dir.mkdir_p(File.join(staging, "incoming", "sub"))
    File.write(File.join(staging, "incoming", "top.rb"), "puts 1")
    File.write(File.join(staging, "incoming", "sub", "inner.rb"), "puts 2")

    watcher = FSEvents.open(root, Array(String).new, DirtyPaths.new(Channel(Nil).new(1)))
    watcher.should be_a(FSEvents)
    next unless watcher.is_a?(FSEvents)

    begin
      sleep(200.milliseconds)
      File.rename(File.join(staging, "incoming"), File.join(root, "incoming"))

      seen = consume_within(watcher, 5.0) do |dirty|
        dirty.is_a?(Everything) ||
          (dirty.is_a?(Touched) && dirty.paths.includes?("incoming/sub/inner.rb"))
      end

      seen.should be_true
    ensure
      watcher.close
      FileUtils.rm_rf(root)
      FileUtils.rm_rf(staging)
    end
  end
end
