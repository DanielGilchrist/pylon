require "../../spec_helper"

require "socket"
require "../../support/remote_end"

private alias Message = Pylon::Wire::Message
private alias ReceivingTree = Pylon::Session::Inbound::ReceivingTree
private alias RemoteEndpoint = Pylon::Session::RemoteEndpoint
private alias Report = Pylon::Session::Report
private alias Fault = Pylon::Session::Fault
private alias RemoteScanning = Pylon::Session::Inbound::RemoteScanning

private def scripted_server(& : IO ->) : IO::Memory
  script = IO::Memory.new
  Pylon::Wire::Greeting.write(script)
  yield script
  script.rewind
  script
end

private def cycle_against(script : IO::Memory) : {Report | Fault, RemoteEndpoint}
  Sandbox.open do |root|
    endpoint = RemoteEndpoint.new(script, IO::Memory.new, remote_configuration(root), resume: nil)
    {build_session(local_endpoint(root), endpoint).cycle(Time.utc.to_unix_ns.to_i64), endpoint}
  end
end

describe "what the client learns while waiting for the remote tree" do
  it "records the remote scan's progress" do
    script = scripted_server do |io|
      Message.write(
        io,
        Pylon::Wire::Message::ScanProgress.new(1234_i64, 5_000_000_i64),
      )
    end

    _, endpoint = cycle_against(script)

    endpoint.inbound.phase.should eq(RemoteScanning.new(1234_i64, 5_000_000_i64))
    endpoint.inbound.bytes.should eq(script.size)
  end

  it "knows how large the announced tree is and how much of it has arrived" do
    root = Pylon::Core::Directory.new(
      {"a.rb" => Pylon::Core::File.new(
        Bytes.new(Pylon::Wire::DIGEST_BYTES, 3_u8),
        executable: false,
      )},
    )
    measured = Pylon::Wire::Chunks.measure_entry(root)

    script = scripted_server do |io|
      Message.write(io, Pylon::Wire::Message::TreeAnnounce.new(measured))
      Message.write(io, Pylon::Wire::Message::ScanResponse.new(root))
    end

    _, endpoint = cycle_against(script)

    phase = endpoint.inbound.phase
    phase.should be_a(ReceivingTree)
    next unless phase.is_a?(ReceivingTree)

    phase.expected.should eq(measured.to_i64)
    endpoint.inbound.received(phase).should eq(measured.to_i64)
  end

  it "hears the real server announce its tree before sending it" do
    Sandbox.open do |sandbox|
      local = sandbox.directory("local")
      remote = sandbox.directory("remote")
      remote.write("pushed.rb", "from the box")

      client, socket = UNIXSocket.pair
      serve_remote_end(socket)

      begin
        endpoint = RemoteEndpoint.new(
          client,
          client,
          remote_configuration(remote, watch: true),
          resume: nil,
        )
        cycle!(build_session(local_endpoint(local), endpoint), Time.utc.to_unix_ns.to_i64)

        phase = endpoint.inbound.phase
        phase.should be_a(ReceivingTree)
        if phase.is_a?(ReceivingTree)
          endpoint.inbound.received(phase).should eq(phase.expected)
        end
      ensure
        client.close
        socket.close
      end
    end
  end
end
