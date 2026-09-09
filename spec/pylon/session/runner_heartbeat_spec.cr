require "../../spec_helper"

require "socket"
require "../../support/remote_end"

describe "a runner watching a silent remote" do
  it "stops when heartbeats go unanswered" do
    Sandbox.open do |sandbox|
      local = sandbox.directory("local")
      remote = sandbox.directory("remote")

      client, server = UNIXSocket.pair
      Pylon::Wire::Greeting.write(server)
      spawn do
        loop do
          message = Pylon::Wire::Message.read(server)
          break unless message.is_a?(Pylon::Wire::Message::Any)

          case message
          when Pylon::Wire::Message::Configure
            Pylon::Wire::Message.write(
              server,
              Pylon::Wire::Message::TreeUpdate.new(0_u32, nil, live: false),
            )
          when Pylon::Wire::Message::WriteRequest
            Pylon::Wire::Message.write(
              server,
              Pylon::Wire::Message::WriteResponse.new(Array(Pylon::Write::Outcome).new),
            )
          end
        end
      end

      dirty_paths = Pylon::Watch::DirtyPaths.new(Channel(Nil).new(1))
      endpoint = Pylon::Session::RemoteEndpoint.new(
        client, client, remote_configuration(remote), dirty_paths.signals, resume: nil)
      session = build_session(local_endpoint(local), endpoint)

      runner = Pylon::Session::Runner.new(
        session,
        dirty_paths,
        poll: 5.milliseconds,
        heartbeat: 20.milliseconds,
        deadline: 40.milliseconds,
      )

      faults = Channel(Pylon::Session::Fault).new(1)
      cycles = Channel(Nil).new(4)
      spawn do
        fault = runner.run { cycles.send(nil) }
        faults.send(fault) if fault
      end

      begin
        await(cycles, for: "the first cycle")
        await(faults, for: "the run to stop because nothing answered")
          .should be_a(Pylon::Session::Disconnected)
      ensure
        runner.stop
        client.close
        server.close
      end
    end
  end
end
