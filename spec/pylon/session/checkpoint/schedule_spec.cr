require "../../../spec_helper"

require "file_utils"

private alias Checkpoint = Pylon::Session::Checkpoint
private alias Problem = Pylon::Problem
private alias Schedule = Pylon::Session::Checkpoint::Schedule

private def in_sandbox(& : String ->) : Nil
  root = File.join(Dir.tempdir, "pylon-schedule-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)

  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def schedule(path : String, interval : Time::Span) : Schedule
  Schedule.new(path, interval)
end

describe Schedule do
  it "saves immediately when it has never saved" do
    in_sandbox do |root|
      path = File.join(root, "state")

      schedule(path, 1.hour).save_if_due(Checkpoint.new)

      File.exists?(path).should be_true
    end
  end

  it "does not save again within the interval" do
    in_sandbox do |root|
      path = File.join(root, "state")
      due = schedule(path, 1.hour)

      due.save_if_due(Checkpoint.new)
      first_write = File.info(path).modification_time

      due.save_if_due(Checkpoint.new)
      File.info(path).modification_time.should eq(first_write)
    end
  end

  it "saves again once the interval has passed" do
    in_sandbox do |root|
      path = File.join(root, "state")
      due = schedule(path, 0.seconds)

      due.save_if_due(Checkpoint.new)
      File.write(path, "clobbered")
      due.save_if_due(Checkpoint.new)

      File.read(path).should_not eq("clobbered")
    end
  end

  it "reports a failed save once rather than on every attempt" do
    in_sandbox do |root|
      blocked = File.join(root, "occupied")
      File.write(blocked, "a file where the state directory should be")

      due = schedule(File.join(blocked, "state"), 0.seconds)

      first = due.save(Checkpoint.new)
      second = due.save(Checkpoint.new)

      first.should be_a(Problem)
      first.reason.should contain("was not saved") if first.is_a?(Problem)
      second.should be_nil
    end
  end

  it "complains again after a save succeeds in between failures" do
    in_sandbox do |root|
      blocked = File.join(root, "occupied")
      File.write(blocked, "in the way")

      due = schedule(File.join(blocked, "state"), 0.seconds)

      due.save(Checkpoint.new).should be_a(Problem)
      File.delete(blocked)
      due.save(Checkpoint.new).should be_nil
      FileUtils.rm_rf(blocked)
      File.write(blocked, "in the way again")
      due.save(Checkpoint.new).should be_a(Problem)
    end
  end
end
