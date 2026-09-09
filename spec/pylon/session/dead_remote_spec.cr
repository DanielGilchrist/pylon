require "../../spec_helper"

require "socket"
require "../../support/remote_end"

describe "a remote that is not there" do
  it "reports the remote stopping rather than taking the process down" do
    Sandbox.open do |root|
      client, socket = UNIXSocket.pair
      socket.close
      client.close

      session = build_session(
        local_endpoint(root),
        Pylon::Session::RemoteEndpoint.new(client, client, remote_configuration(root), resume: nil),
      )

      session.cycle(Time.utc.to_unix_ns.to_i64).should be_a(Pylon::Session::Stopped)
    end
  end

  it "wakes a watching run as soon as the remote goes away, with nothing else happening" do
    Sandbox.open do |sandbox|
      local = sandbox.directory("local")
      remote = sandbox.directory("remote")

      client, socket = UNIXSocket.pair
      serve_remote_end(socket)
      dirty_paths = Pylon::Watch::DirtyPaths.new(Channel(Nil).new(1))

      session = build_session(
        local_endpoint(local),
        Pylon::Session::RemoteEndpoint.new(
          client,
          client,
          remote_configuration(remote),
          dirty_paths.signals,
          resume: nil,
        ),
      )

      # A poll long enough that only the endpoint speaking up can end this run.
      runner = Pylon::Session::Runner.new(
        session,
        dirty_paths,
        debounce: 1.millisecond,
        poll: 1.hour,
      )

      cycles = Channel(Nil).new(4)
      faults = Channel(Pylon::Session::Fault).new(1)

      spawn do
        fault = runner.run { cycles.send(nil) }
        faults.send(fault) if fault
      end

      begin
        await(cycles, for: "the first cycle, after which the run is asleep")

        socket.close

        await(faults, for: "the run to stop because the remote did")
          .should be_a(Pylon::Session::Disconnected)
      ensure
        runner.stop
        client.close
        socket.close
      end
    end
  end
end
