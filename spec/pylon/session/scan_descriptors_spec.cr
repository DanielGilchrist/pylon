require "../../spec_helper"

require "file_utils"
require "socket"
require "../../support/remote_end"

private alias RemoteEndpoint = Pylon::Session::RemoteEndpoint

private def tick : Int64
  Time.utc.to_unix_ns.to_i64 + Random.rand(1_000_000_i64)
end

describe "server scans" do
  it "does not hold onto file descriptors across cycles" do
    base = File.join(Dir.tempdir, "pylon-descriptors-#{Random::Secure.hex(8)}")
    local_root = File.join(base, "local")
    remote_root = File.join(base, "remote")
    Dir.mkdir_p(local_root)
    Dir.mkdir_p(remote_root)
    File.write(File.join(remote_root, "thing.rb"), "puts 1")

    client, socket = UNIXSocket.pair
    serve_remote_end(socket)

    begin
      remote = RemoteEndpoint.new(client, client, remote_configuration(remote_root), resume: nil)
      session = build_session(local_endpoint(local_root), remote)

      cycle!(session, tick)

      assert_descriptor_change(0) do
        30.times do |round|
          File.write(File.join(remote_root, "thing.rb"), "puts #{round}")
          cycle!(session, tick)
        end
      end
    ensure
      client.close
      socket.close
      FileUtils.rm_rf(base)
    end
  end
end
