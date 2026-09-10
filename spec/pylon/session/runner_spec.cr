require "../../spec_helper"

private alias DirtyPaths = Pylon::Watch::DirtyPaths
private alias LocalEndpoint = Pylon::Session::LocalEndpoint
private alias Report = Pylon::Session::Report
private alias Runner = Pylon::Session::Runner

private def burst(dirty_paths : DirtyPaths) : Nil
  Pylon::Session::Runner::BURST_PATHS.times { |index| dirty_paths.add("burst_#{index}.rb") }
  dirty_paths.signals.send(nil)
end

private def release(dirty_paths : DirtyPaths) : Nil
  select
  when dirty_paths.signals.receive?
  else
  end
end

private def cycles : Channel(Report)
  Channel(Report).new(16)
end

private def in_pair(
  & : Sandbox, Sandbox, Pylon::Session::Session(LocalEndpoint, LocalEndpoint, Pylon::Discard) ->
) : Nil
  Sandbox.open do |sandbox|
    local = sandbox.directory("local")
    remote = sandbox.directory("remote")

    yield local, remote, build_session(local_endpoint(local), local_endpoint(remote))
  end
end

describe Runner do
  it "cycles once immediately, before any change arrives" do
    in_pair do |local, remote, session|
      local.write("first.rb", "x")

      runner = Runner.new(
        session,
        DirtyPaths.new(Channel(Nil).new(1)),
        debounce: 1.millisecond,
        poll: 10.milliseconds,
      )
      reports = cycles

      spawn do
        runner.run do |report, _elapsed|
          reports.send(report)
          runner.stop
        end
      end

      await(reports, for: "the first cycle")

      remote.read("first.rb").should eq("x")
      never_arrives(reports, for: "a second cycle", within: 30.milliseconds)
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
      reports = cycles

      spawn { runner.run { |report, _elapsed| reports.send(report) } }

      await(reports, for: "the first cycle")

      local.write("later.rb", "y")
      dirty_paths.add("later.rb")
      dirty_paths.signals.send(nil)
      await(reports, for: "the cycle the signal asked for")

      runner.stop
      remote.read("later.rb").should eq("y")
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
      reports = cycles

      spawn { runner.run { |report, _elapsed| reports.send(report) } }

      await(reports, for: "the first cycle")
      never_arrives(reports, for: "a second cycle", within: 80.milliseconds)

      runner.stop
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
      reports = cycles

      spawn { runner.run { |report, _elapsed| reports.send(report) } }

      await(reports, for: "the first cycle")

      10.times do |index|
        local.write("burst_#{index}.rb", "b")
        burst(dirty_paths)
      end

      coalesced = await(reports, for: "the cycle for the burst")
      never_arrives(reports, for: "a second cycle for the same burst", within: 80.milliseconds)
      runner.stop

      coalesced.remote_outcomes.count(&.applied?).should eq(10)
    end
  end

  it "keeps waiting while signals keep arriving" do
    in_pair do |local, _, session|
      dirty_paths = DirtyPaths.new(Channel(Nil).new)
      runner = Runner.new(
        session,
        dirty_paths,
        debounce: 1.millisecond,
        poll: 1.second,
        burst_quiet: 120.milliseconds,
      )
      reports = cycles

      spawn { runner.run { |report, _elapsed| reports.send(report) } }

      await(reports, for: "the first cycle")

      5.times do |index|
        local.write("spread_#{index}.rb", "s")
        burst(dirty_paths)
      end

      coalesced = await(reports, for: "the cycle for the signals that kept arriving")
      never_arrives(reports, for: "a second cycle for the same signals", within: 80.milliseconds)
      runner.stop

      coalesced.remote_outcomes.count(&.applied?).should eq(5)
    end
  end

  it "cycles anyway when a burst never goes quiet" do
    in_pair do |local, _, session|
      dirty_paths = DirtyPaths.new(Channel(Nil).new)
      runner = Runner.new(
        session,
        dirty_paths,
        debounce: 1.millisecond,
        poll: 1.second,
        burst_quiet: 1.hour,
        settle_limit: 20.milliseconds,
      )
      reports = cycles

      spawn { runner.run { |report, _elapsed| reports.send(report) } }

      await(reports, for: "the first cycle")

      local.write("endless.rb", "e")
      Runner::BURST_PATHS.times { |index| dirty_paths.add("endless_#{index}.rb") }
      streaming = true

      spawn do
        while streaming
          dirty_paths.signals.send(nil)
        end
      end

      forced = await(reports, for: "the cycle the settle limit forced")
      streaming = false
      release(dirty_paths)
      runner.stop

      forced.remote_outcomes.count(&.applied?).should eq(1)
    end
  end
end
