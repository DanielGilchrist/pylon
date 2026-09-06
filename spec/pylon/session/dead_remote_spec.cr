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
end
