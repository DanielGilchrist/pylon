require "../../spec_helper"

Pylon::Platform.skip_file_unless :macos

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
    Sandbox.open do |sandbox|
      root = sandbox.directory("root")
      root.directory("log")

      watcher = FSEvents.open(root.root, ["log"], DirtyPaths.new(Channel(Nil).new(1)))
      watcher.should be_a(FSEvents)
      next unless watcher.is_a?(FSEvents)

      begin
        sleep(200.milliseconds)
        root.write("code.rb", "puts 1")

        seen = consume_within(watcher, 5.0) do |dirty|
          dirty.is_a?(Everything) || (dirty.is_a?(Touched) && dirty.paths.includes?("code.rb"))
        end
        seen.should be_true

        root.directory("nested/deeper")
        root.write("nested/deeper/inner.rb", "puts 2")

        seen = consume_within(watcher, 5.0) do |dirty|
          next true if dirty.is_a?(Everything)

          dirty.is_a?(Touched) && dirty.paths.any?(&.starts_with?("nested"))
        end
        seen.should be_true

        root.write("log/noise.log", "ignored")
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
      end
    end
  end

  it "reports the files inside a directory moved into the root" do
    Sandbox.open do |sandbox|
      root = sandbox.directory("root")
      staging = sandbox.directory("staging")
      staging.directory("incoming/sub")
      staging.write("incoming/top.rb", "puts 1")
      staging.write("incoming/sub/inner.rb", "puts 2")

      watcher = FSEvents.open(root.root, Array(String).new, DirtyPaths.new(Channel(Nil).new(1)))
      watcher.should be_a(FSEvents)
      next unless watcher.is_a?(FSEvents)

      begin
        sleep(200.milliseconds)
        File.rename(staging.path("incoming"), root.path("incoming"))

        seen = consume_within(watcher, 5.0) do |dirty|
          dirty.is_a?(Everything) ||
            (dirty.is_a?(Touched) && dirty.paths.includes?("incoming/sub/inner.rb"))
        end

        seen.should be_true
      ensure
        watcher.close
      end
    end
  end
end
