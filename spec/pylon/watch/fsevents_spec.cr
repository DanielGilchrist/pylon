require "../../spec_helper"

Pylon::Platform.skip_file_unless :macos

private alias DirtyPaths = Pylon::Watch::DirtyPaths
private alias Everything = Pylon::Watch::Everything
private alias FSEvents = Pylon::Watch::FSEvents
private alias Touched = Pylon::Watch::Touched

# `consume` empties the watcher, so an example that asks several questions of one run has to keep
# what it has already been told.
private class Seen
  def initialize(@watcher : FSEvents) : Nil
    @paths = Set(String).new
    @flushed = false
  end

  getter paths : Set(String)

  def flushed? : Bool
    @flushed
  end

  def refresh : Nil
    case (dirty = @watcher.dirty_paths.consume)
    in Everything then @flushed = true
    in Touched    then @paths.concat(dirty.paths)
    end
  end
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
        seen = Seen.new(watcher)

        root.write("code.rb", "puts 1")
        await(watcher.dirty_paths.signals, for: "a signal from the watcher") do
          seen.refresh
          seen.flushed? || seen.paths.includes?("code.rb")
        end

        root.directory("nested/deeper")
        root.write("nested/deeper/inner.rb", "puts 2")
        await(watcher.dirty_paths.signals, for: "a signal from the watcher") do
          seen.refresh
          seen.flushed? || seen.paths.any?(&.starts_with?("nested"))
        end

        # The stream reports in the order the writes happened, so once the later write has landed
        # the ignored one would have landed too if it were ever going to.
        root.write("log/noise.log", "ignored")
        root.write("after_the_noise.rb", "puts 3")
        await(watcher.dirty_paths.signals, for: "a signal from the watcher") do
          seen.refresh
          seen.flushed? || seen.paths.includes?("after_the_noise.rb")
        end

        seen.flushed?.should be_false, "expected per-path events, saw a fresh-instance flush"
        seen.paths.none?(&.starts_with?("log")).should be_true
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
        seen = Seen.new(watcher)

        File.rename(staging.path("incoming"), root.path("incoming"))

        await(watcher.dirty_paths.signals, for: "a signal from the watcher") do
          seen.refresh
          seen.flushed? || seen.paths.includes?("incoming/sub/inner.rb")
        end
      ensure
        watcher.close
      end
    end
  end
end
