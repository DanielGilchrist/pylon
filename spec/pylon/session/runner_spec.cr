require "../../spec_helper"

require "file_utils"

private alias DirtyPaths = Pylon::Watch::DirtyPaths
private alias LocalEndpoint = Pylon::Session::LocalEndpoint
private alias Report = Pylon::Session::Report
private alias Runner = Pylon::Session::Runner

private def burst(dirty_paths : DirtyPaths) : Nil
  Pylon::Session::Runner::BURST_PATHS.times { |index| dirty_paths.add("burst_#{index}.rb") }
  dirty_paths.signals.send(nil)
end

private def in_pair(
  & : String, String, Pylon::Session::Session(LocalEndpoint, LocalEndpoint, Pylon::Discard) ->
) : Nil
  base = File.join(Dir.tempdir, "pylon-runner-#{Random::Secure.hex(8)}")
  local = File.join(base, "local")
  remote = File.join(base, "remote")
  Dir.mkdir_p(local)
  Dir.mkdir_p(remote)

  begin
    yield local, remote, build_session(local_endpoint(local), local_endpoint(remote))
  ensure
    FileUtils.rm_rf(base)
  end
end

describe Runner do
  it "cycles once immediately, before any change arrives" do
    in_pair do |local, remote, session|
      File.write(File.join(local, "first.rb"), "x")

      runner = Runner.new(
        session,
        DirtyPaths.new(Channel(Nil).new(1)),
        debounce: 1.millisecond,
        poll: 10.milliseconds,
      )
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
      dirty_paths = DirtyPaths.new(Channel(Nil).new(1))
      runner = Runner.new(
        session,
        dirty_paths,
        debounce: 1.millisecond,
        poll: 1.second,
      )
      reports = Array(Report).new

      spawn { runner.run { |report, _elapsed| reports << report } }

      Fiber.yield
      sleep 30.milliseconds
      reports.size.should eq(1)

      File.write(File.join(local, "later.rb"), "y")
      dirty_paths.add("later.rb")
      dirty_paths.signals.send(nil)
      sleep 60.milliseconds

      runner.stop
      File.read(File.join(remote, "later.rb")).should eq("y")
      reports.size.should be >= 2
    end
  end

  it "does not cycle while nothing is happening" do
    in_pair do |_, _, session|
      runner = Runner.new(
        session,
        DirtyPaths.new(Channel(Nil).new(1)),
        debounce: 1.millisecond,
        poll: 10.milliseconds,
      )
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
      dirty_paths = DirtyPaths.new(Channel(Nil).new(16))
      runner = Runner.new(
        session,
        dirty_paths,
        debounce: 30.milliseconds,
        poll: 1.second,
        burst_quiet: 20.milliseconds,
      )
      reports = Array(Report).new

      spawn { runner.run { |report, _elapsed| reports << report } }

      Fiber.yield
      sleep 20.milliseconds

      10.times do |index|
        File.write(File.join(local, "burst_#{index}.rb"), "b")
        burst(dirty_paths)
      end

      sleep 150.milliseconds
      runner.stop

      reports.size.should eq(2)
      reports.last.remote_outcomes.count(&.applied?).should eq(10)
    end
  end

  it "keeps waiting while signals arrive in gaps longer than the debounce" do
    in_pair do |local, _, session|
      dirty_paths = DirtyPaths.new(Channel(Nil).new(16))
      runner = Runner.new(
        session,
        dirty_paths,
        debounce: 2.milliseconds,
        poll: 1.second,
        burst_quiet: 120.milliseconds,
      )
      reports = Array(Report).new

      spawn { runner.run { |report, _elapsed| reports << report } }

      Fiber.yield
      sleep 20.milliseconds

      5.times do |index|
        File.write(File.join(local, "spread_#{index}.rb"), "s")
        burst(dirty_paths)
        burst(dirty_paths)
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
      dirty_paths = DirtyPaths.new(Channel(Nil).new(16))
      runner = Runner.new(
        session,
        dirty_paths,
        debounce: 2.milliseconds,
        poll: 1.second,
        burst_quiet: 60.milliseconds,
        settle_limit: 100.milliseconds,
      )
      reports = Array(Report).new

      spawn { runner.run { |report, _elapsed| reports << report } }

      Fiber.yield
      sleep 20.milliseconds

      File.write(File.join(local, "endless.rb"), "e")
      dirty_paths.add("endless.rb")
      streaming = true

      spawn do
        while streaming
          select
          when dirty_paths.signals.send(nil)
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
