require "file_utils"
require "../../spec_helper"
require "../../../src/pylon/watch/client"

include Pylon::Watch

private def watchman_socket : String?
  Client(UNIXSocket).socket_path
end

describe "Pylon::Watch::Client against a live daemon" do
  socket = watchman_socket

  if socket.nil?
    pending "watchman is not available on this machine"
  else
    it "subscribes and receives a fresh instance followed by a live change" do
      root = File.join(Dir.tempdir, "pylon-watch-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(File.join(root, "keep"))
      File.write(File.join(root, "keep", "seed.txt"), "seed")

      client = Client(UNIXSocket).connect(socket)
      client.should be_a(Client(UNIXSocket))
      next unless client.is_a?(Client(UNIXSocket))

      begin
        client.watch_project(root).should be_a(PDU::Response)
        client.subscribe(root, "pylon-spec", ["ignored"]).should be_a(PDU::Response)

        first = client.read
        first.should be_a(PDU::Snapshot)
        next unless first.is_a?(PDU::Snapshot)

        first.observations.map(&.name).should contain("keep/seed.txt")
        first.clock.should start_with("c:")

        File.write(File.join(root, "added.txt"), "x")

        seen = [] of String
        4.times do
          pdu = client.read
          break unless pdu.is_a?(PDU::Delta)

          seen.concat(pdu.observations.map(&.name))
          break if seen.includes?("added.txt")
        end

        seen.should contain("added.txt")
      ensure
        client.close
        Process.run("watchman", ["watch-del", root])
        FileUtils.rm_rf(root)
      end
    end
  end
end
