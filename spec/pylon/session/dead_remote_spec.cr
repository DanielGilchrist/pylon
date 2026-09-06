require "../../spec_helper"

require "file_utils"
require "socket"
require "../../support/remote_end"

describe "a remote that is not there" do
  it "reports the remote stopping rather than taking the process down" do
    root = File.join(Dir.tempdir, "pylon-dead-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(root)

    client, socket = UNIXSocket.pair
    socket.close
    client.close

    session = build_session(
      local_endpoint(root),
      Pylon::Session::RemoteEndpoint.new(client, client, remote_configuration(root), resume: nil),
    )

    begin
      session.cycle(Time.utc.to_unix_ns.to_i64).should be_a(Pylon::Session::Stopped)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
