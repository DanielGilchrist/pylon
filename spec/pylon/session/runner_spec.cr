require "file_utils"
require "../../spec_helper"
require "../../../src/pylon/session/local_endpoint"
require "../../../src/pylon/session/runner"

include Pylon::Session

private def in_pair(& : String, String, Session(LocalEndpoint, LocalEndpoint) ->) : Nil
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
      reports = Array(Report).new

      spawn do
        runner.run do |report, _elapsed|
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
      reports = Array(Report).new

      spawn { runner.run { |report, _elapsed| reports << report } }

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

  it "does not cycle while nothing is happening" do
    in_pair do |_, _, session|
      runner = Runner.new(session, Channel(Nil).new(1), debounce: 1.millisecond, poll: 10.milliseconds)
      reports = Array(Report).new

      spawn { runner.run { |report, _elapsed| reports << report } }

      Fiber.yield
      sleep 80.milliseconds
      runner.stop

      reports.size.should eq(1)
    end
  end

  it "coalesces a burst of signals into a single cycle" do
    in_pair do |local, _, session|
      signals = Channel(Nil).new(16)
      runner = Runner.new(session, signals, debounce: 30.milliseconds, poll: 1.second, burst_quiet: 20.milliseconds)
      reports = Array(Report).new

      spawn { runner.run { |report, _elapsed| reports << report } }

      Fiber.yield
      sleep 20.milliseconds

      10.times do |index|
        File.write(File.join(local, "burst_#{index}.rb"), "b")
        signals.send(nil)
      end

      sleep 150.milliseconds
      runner.stop

      reports.size.should eq(2)
      reports.last.remote_outcomes.count(&.applied?).should eq(10)
    end
  end

  it "keeps waiting while signals arrive in gaps longer than the debounce" do
    in_pair do |local, _, session|
      signals = Channel(Nil).new(16)
      runner = Runner.new(session, signals, debounce: 2.milliseconds, poll: 1.second, burst_quiet: 120.milliseconds, gauge: -> : Int32 { 100 })
      reports = Array(Report).new

      spawn { runner.run { |report, _elapsed| reports << report } }

      Fiber.yield
      sleep 20.milliseconds

      5.times do |index|
        File.write(File.join(local, "spread_#{index}.rb"), "s")
        signals.send(nil)
        signals.send(nil)
        sleep 25.milliseconds
      end

      sleep 250.milliseconds
      runner.stop

      reports.size.should eq(2)
      reports.last.remote_outcomes.count(&.applied?).should eq(5)
    end
  end

  it "cycles anyway when a burst never goes quiet" do
    in_pair do |local, _, session|
      signals = Channel(Nil).new(16)
      runner = Runner.new(session, signals, debounce: 2.milliseconds, poll: 1.second, burst_quiet: 60.milliseconds, settle_limit: 100.milliseconds, gauge: -> : Int32 { 100 })
      reports = Array(Report).new

      spawn { runner.run { |report, _elapsed| reports << report } }

      Fiber.yield
      sleep 20.milliseconds

      File.write(File.join(local, "endless.rb"), "e")
      streaming = true

      spawn do
        while streaming
          select
          when signals.send(nil)
          else
          end

          sleep 20.milliseconds
        end
      end

      sleep 400.milliseconds
      streaming = false
      runner.stop

      reports.size.should be >= 2
      reports[1].remote_outcomes.count(&.applied?).should eq(1)
    end
  end
end
