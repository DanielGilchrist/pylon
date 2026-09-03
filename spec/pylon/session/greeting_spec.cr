require "file_utils"
require "socket"
require "../../spec_helper"
require "../../../src/pylon/session/server"
require "../../../src/pylon/session/local_endpoint"
require "../../../src/pylon/session/remote_endpoint"
require "../../../src/pylon/session/session"
require "../../support/remote_end"

include Pylon::Session

private class BufferedIO < IO
  include IO::Buffered

  getter inner = IO::Memory.new

  def unbuffered_read(slice : Bytes) : Int32
    @inner.read(slice)
  end

  def unbuffered_write(slice : Bytes) : Nil
    @inner.write(slice)
  end

  def unbuffered_flush : Nil
  end

  def unbuffered_close : Nil
  end

  def unbuffered_rewind : Nil
  end
end

private def rejected_with(message : String, brand : Pylon::Brand = Pylon::Brand::DEFAULT, & : UNIXSocket ->) : Nil
  root = File.join(Dir.tempdir, "pylon-greeting-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)

  client, socket = UNIXSocket.pair

  begin
    yield socket
    session = Session.new(LocalEndpoint.new(root), RemoteEndpoint.new(client, client, remote_configuration(root, brand: brand)))

    result = session.cycle(Time.utc.to_unix_ns.to_i64)

    fail "expected an incompatible fault, got #{result.class}" unless result.is_a?(Incompatible)
    result.explain.should contain(message)
  ensure
    client.close
    socket.close
    FileUtils.rm_rf(root)
  end
end

describe "the wire greeting" do
  it "rejects a remote built for a different protocol version" do
    rejected_with("version 0") do |socket|
      socket.write(Pylon::Wire::IDENTITY.to_slice)
      socket.write_bytes(0_u32, Pylon::Wire::FORMAT)
      socket.flush
    end
  end

  it "rejects a remote that responds with something else entirely" do
    rejected_with("did not identify itself as pylon") do |socket|
      socket.puts("bash: pylon: command not found")
      socket.flush
    end
  end

  it "names the program it expected by the name it was given" do
    rejected_with("did not identify itself as Test Sync", brand: Pylon::Brand.new("Test Sync")) do |socket|
      socket.puts("bash: pylon: command not found")
      socket.flush
    end
  end

  it "flushes the greeting so a buffered stdout cannot hold it back while the server waits to be configured" do
    buffered = BufferedIO.new

    Pylon::Wire::Greeting.write(buffered)

    buffered.inner.to_s.should start_with(Pylon::Wire::IDENTITY)
  end

  it "refuses to start when the greeting cannot be sent" do
    closed = IO::Memory.new
    closed.close

    accepted = Server.accept(IO::Memory.new, closed, IO::Memory.new)

    accepted.should be_a(Pylon::Problem)
    accepted.reason.should start_with("the greeting could not be sent") if accepted.is_a?(Pylon::Problem)
  end

  it "is sent by the server before anything else" do
    client, socket = UNIXSocket.pair
    serve_remote_end(socket)

    begin
      identity = Bytes.new(Pylon::Wire::IDENTITY.bytesize)
      client.read_fully(identity)

      String.new(identity).should eq(Pylon::Wire::IDENTITY)
      client.read_bytes(UInt32, Pylon::Wire::FORMAT).should eq(Pylon::Wire::PROTOCOL)
    ensure
      client.close
      socket.close
    end
  end

  it "refuses a client whose first message is not a configuration" do
    client, socket = UNIXSocket.pair

    begin
      Pylon::Wire::Message.write(client, Pylon::Wire::Message::ScanRequest.new(1_i64))

      accepted = Server.accept(socket, socket, IO::Memory.new)

      accepted.should be_a(Pylon::Problem)
      accepted.reason.should contain("must configure this side") if accepted.is_a?(Pylon::Problem)
      Pylon::Wire::Greeting.read(client).should be_a(Pylon::Wire::Greeting::Compatible)
      Pylon::Wire::Message.read(client).should be_a(Pylon::Wire::Message::Failure)
    ensure
      client.close
      socket.close
    end
  end

  it "takes its brand from the client's configuration" do
    root = File.join(Dir.tempdir, "pylon-greeting-#{Random::Secure.hex(8)}")
    state = File.join(Dir.tempdir, "pylon-greeting-state-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(root)
    File.write(state, "not a state file")
    client, socket = UNIXSocket.pair
    log = IO::Memory.new

    begin
      configure = Pylon::Wire::Message::Configure.new(
        root: root,
        ignores: Array(String).new,
        compression: Pylon::Compress::Zstd::DEFAULT_LEVEL,
        brand: Pylon::Brand.new("Test Sync"),
        state: state,
        watch: false,
      )
      Pylon::Wire::Message.write(client, configure)

      Server.accept(socket, socket, log).should be_a(Server)

      log.to_s.should start_with("Test Sync: ignoring the sync state at #{state}")
    ensure
      client.close
      socket.close
      File.delete(state)
      FileUtils.rm_rf(root)
    end
  end
end
