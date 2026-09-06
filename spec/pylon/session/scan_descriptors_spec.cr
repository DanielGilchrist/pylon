require "../../spec_helper"

require "socket"
require "../../support/remote_end"

private alias RemoteEndpoint = Pylon::Session::RemoteEndpoint

private def tick : Int64
  Time.utc.to_unix_ns.to_i64 + Random.rand(1_000_000_i64)
end

describe "server scans" do
  it "does not hold onto file descriptors across cycles" do
    Sandbox.open do |sandbox|
      local_root = sandbox.directory("local")
      remote_root = sandbox.directory("remote")
      remote_root.write("thing.rb", "puts 1")

      client, socket = UNIXSocket.pair
      serve_remote_end(socket)

      begin
        remote = RemoteEndpoint.new(client, client, remote_configuration(remote_root), resume: nil)
        session = build_session(local_endpoint(local_root), remote)

        cycle!(session, tick)

        assert_descriptor_change(0) do
          30.times do |round|
            remote_root.write("thing.rb", "puts #{round}")
            cycle!(session, tick)
          end
        end
      ensure
        client.close
        socket.close
      end
    end
  end
end
