{% skip_file unless flag?(:darwin) %}

require "file_utils"
require "../../spec_helper"
require "../../../src/pylon/watch/fsevents"

include Pylon::Watch

private def drain_within(watcher : FSEvents, seconds : Float64, & : Dirty -> Bool) : Bool
  deadline = Time.instant + seconds.seconds

  while Time.instant < deadline
    return true if yield watcher.drain

    sleep(50.milliseconds)
  end

  false
end

describe Pylon::Watch::FSEvents do
  it "reports touched paths, nested creations and respects ignores" do
    root = File.tempname("pylon-fsevents")
    Dir.mkdir_p(File.join(root, "log"))

    watcher = FSEvents.open(root, ["log"])
    watcher.should be_a(FSEvents)
    next unless watcher.is_a?(FSEvents)

    begin
      sleep(200.milliseconds)
      File.write(File.join(root, "code.rb"), "puts 1")

      seen = drain_within(watcher, 5.0) do |dirty|
        dirty.is_a?(Everything) || (dirty.is_a?(Touched) && dirty.paths.includes?("code.rb"))
      end
      seen.should be_true

      Dir.mkdir_p(File.join(root, "nested", "deeper"))
      File.write(File.join(root, "nested", "deeper", "inner.rb"), "puts 2")

      seen = drain_within(watcher, 5.0) do |dirty|
        dirty.is_a?(Everything) || (dirty.is_a?(Touched) && dirty.paths.any?(&.starts_with?("nested")))
      end
      seen.should be_true

      File.write(File.join(root, "log", "noise.log"), "ignored")
      sleep(400.milliseconds)

      leftover = watcher.drain
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
end
