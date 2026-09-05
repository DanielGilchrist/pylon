require "file_utils"
require "../../spec_helper"
require "../../../src/pylon/session/local_endpoint"
require "../../../src/pylon/session/remote_endpoint"
require "../../../src/pylon/session/session"
require "../../support/remote_end"

include Pylon::Session

private def scripted_server(& : IO ->) : IO::Memory
  script = IO::Memory.new
  Pylon::Wire::Greeting.write(script)
  yield script
  script.rewind
  script
end

private def cycle_against(script : IO::Memory, watch : Bool = false) : Report | Fault
  root = File.join(Dir.tempdir, "pylon-misbehaving-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)

  begin
    session = build_session(
      local_endpoint(root),
      RemoteEndpoint.new(
        script,
        IO::Memory.new,
        remote_configuration(root, watch: watch),
        resume: nil,
      ),
    )
    session.cycle(Time.utc.to_unix_ns.to_i64)
  ensure
    FileUtils.rm_rf(root)
  end
end

describe "a remote that misbehaves" do
  it "stops with the failure a server reports instead of waiting for a reply" do
    script = scripted_server do |io|
      Pylon::Wire::Message.write(io, Pylon::Wire::Message::Failure.new("the disk is full"))
    end

    fault = cycle_against(script)

    fault.should be_a(Misbehaved)
    fault.explain.should contain("the disk is full") if fault.is_a?(Fault)
  end

  it "stops when replies pile up that nothing asked for instead of hanging" do
    script = scripted_server do |io|
      (Session::WRITE_WINDOW + 1).times do
        Pylon::Wire::Message.write(
          io,
          Pylon::Wire::Message::WriteResponse.new(Array(Pylon::Write::Outcome).new),
        )
      end
    end

    fault = cycle_against(script)

    fault.should be_a(Misbehaved)
    fault.explain.should contain("nothing was waiting for") if fault.is_a?(Fault)
  end

  it "stops instead of waiting forever for a first tree the server never pushes" do
    script = scripted_server { }

    fault = cycle_against(script, watch: true)

    fault.should be_a(Stopped)
  end

  it "stops when the server sends a message only clients send" do
    script = scripted_server do |io|
      Pylon::Wire::Message.write(io, Pylon::Wire::Message::ScanRequest.new(1_i64))
    end

    fault = cycle_against(script)

    fault.should be_a(Misbehaved)
    fault.explain.should contain("only clients send") if fault.is_a?(Fault)
  end
end
