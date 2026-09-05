require "file_utils"
require "../../../spec_helper"
require "../../../../src/pylon/session/checkpoint/schedule"

include Pylon::Session

private def in_sandbox(& : String ->) : Nil
  root = File.join(Dir.tempdir, "pylon-schedule-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)

  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def schedule(
  path : String,
  interval : Time::Span,
  problems : Array(String),
) : Checkpoint::Schedule
  Checkpoint::Schedule.new(
    path,
    -> : Checkpoint { Checkpoint.new },
    interval: interval,
    on_problem: ->(problem : String) : Nil { problems << problem },
  )
end

describe Pylon::Session::Checkpoint::Schedule do
  it "saves immediately when it has never saved" do
    in_sandbox do |root|
      path = File.join(root, "state")

      schedule(path, 1.hour, Array(String).new).save_if_due

      File.exists?(path).should be_true
    end
  end

  it "does not save again within the interval" do
    in_sandbox do |root|
      path = File.join(root, "state")
      due = schedule(path, 1.hour, Array(String).new)

      due.save_if_due
      first_write = File.info(path).modification_time

      due.save_if_due
      File.info(path).modification_time.should eq(first_write)
    end
  end

  it "saves again once the interval has passed" do
    in_sandbox do |root|
      path = File.join(root, "state")
      due = schedule(path, 0.seconds, Array(String).new)

      due.save_if_due
      File.write(path, "clobbered")
      due.save_if_due

      File.read(path).should_not eq("clobbered")
    end
  end

  it "reports a failed save once rather than on every attempt" do
    in_sandbox do |root|
      blocked = File.join(root, "occupied")
      File.write(blocked, "a file where the state directory should be")

      problems = Array(String).new
      due = schedule(File.join(blocked, "state"), 0.seconds, problems)

      due.save
      due.save

      problems.size.should eq(1)
      problems.first.should contain("was not saved")
    end
  end

  it "complains again after a save succeeds in between failures" do
    in_sandbox do |root|
      blocked = File.join(root, "occupied")
      File.write(blocked, "in the way")

      problems = Array(String).new
      due = schedule(File.join(blocked, "state"), 0.seconds, problems)

      due.save
      File.delete(blocked)
      due.save
      FileUtils.rm_rf(blocked)
      File.write(blocked, "in the way again")
      due.save

      problems.size.should eq(2)
    end
  end
end
