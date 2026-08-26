require "file_utils"
require "../../spec_helper"
require "../../../src/pylon/session/local_endpoint"
require "../../../src/pylon/session/runner"

include Pylon::Session

private def in_pair(& : String, String, Session(LocalEndpoint, LocalEndpoint) ->)
  base = File.join(Dir.tempdir, "pylon-runner-#{Random::Secure.hex(8)}")
  local = File.join(base, "local")
  remote = File.join(base, "remote")
  Dir.mkdir_p(local)
  Dir.mkdir_p(remote)

  begin
    yield local, remote, Session.new(LocalEndpoint.new(local), LocalEndpoint.new(remote))
  ensure
    FileUtils.rm_rf(base)
  end
end

describe Pylon::Session::Runner do
  it "cycles once immediately, before any change arrives" do
    in_pair do |local, remote, session|
      File.write(File.join(local, "first.rb"), "x")

      runner = Runner.new(session, Channel(Nil).new(1), debounce: 1.millisecond, poll: 10.milliseconds)
      reports = [] of Report

      spawn do
        runner.run do |report|
          reports << report
          runner.stop
        end
      end

      Fiber.yield
      sleep 50.milliseconds

      File.read(File.join(remote, "first.rb")).should eq("x")
      reports.size.should eq(1)
    end
  end

  it "cycles again when a signal arrives" do
    in_pair do |local, remote, session|
      signals = Channel(Nil).new(1)
      runner = Runner.new(session, signals, debounce: 1.millisecond, poll: 1.second)
      reports = [] of Report

      spawn { runner.run { |report| reports << report } }

      Fiber.yield
      sleep 30.milliseconds
      reports.size.should eq(1)

      File.write(File.join(local, "later.rb"), "y")
      signals.send(nil)
      sleep 60.milliseconds

      runner.stop
      File.read(File.join(remote, "later.rb")).should eq("y")
      reports.size.should be >= 2
    end
  end

  it "cycles when the remote reports a change" do
    in_pair do |_, remote, session|
      remote_changed = true
      runner = Runner.new(
        session,
        Channel(Nil).new(1),
        debounce: 1.millisecond,
        poll: 10.milliseconds,
        remote_poll: -> { value = remote_changed; remote_changed = false; value },
      )
      reports = [] of Report

      spawn { runner.run { |report| reports << report } }

      Fiber.yield
      File.write(File.join(remote, "from_remote.rb"), "z")
      sleep 80.milliseconds
      runner.stop

      reports.size.should be >= 2
    end
  end

  it "does not cycle while nothing is happening" do
    in_pair do |_, _, session|
      runner = Runner.new(session, Channel(Nil).new(1), debounce: 1.millisecond, poll: 10.milliseconds)
      reports = [] of Report

      spawn { runner.run { |report| reports << report } }

      Fiber.yield
      sleep 80.milliseconds
      runner.stop

      reports.size.should eq(1)
    end
  end

  it "coalesces a burst of signals into a single cycle" do
    in_pair do |local, _, session|
      signals = Channel(Nil).new(16)
      runner = Runner.new(session, signals, debounce: 30.milliseconds, poll: 1.second)
      reports = [] of Report

      spawn { runner.run { |report| reports << report } }

      Fiber.yield
      sleep 20.milliseconds

      10.times do |index|
        File.write(File.join(local, "burst_#{index}.rb"), "b")
        signals.send(nil)
      end

      sleep 120.milliseconds
      runner.stop

      reports.size.should eq(2)
      reports.last.remote_outcomes.count(&.applied?).should eq(10)
    end
  end
end
