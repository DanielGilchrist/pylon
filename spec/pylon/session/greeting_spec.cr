require "file_utils"
require "socket"
require "../../spec_helper"
require "../../../src/pylon/session/server"
require "../../../src/pylon/session/local_endpoint"
require "../../../src/pylon/session/remote_endpoint"
require "../../../src/pylon/session/session"

include Pylon::Session

private def rejected_with(message : String, brand : Pylon::Brand = Pylon::Brand::DEFAULT, & : UNIXSocket ->) : Nil
  root = File.join(Dir.tempdir, "pylon-greeting-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)

  client, socket = UNIXSocket.pair

  begin
    yield socket
    session = Session.new(LocalEndpoint.new(root), RemoteEndpoint.new(client, client, brand: brand))

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

  it "signs the server log with the given name when the greeting cannot be sent" do
    root = File.join(Dir.tempdir, "pylon-greeting-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(root)
    closed = IO::Memory.new
    closed.close
    log = IO::Memory.new

    begin
      Server.new(LocalEndpoint.new(root), IO::Memory.new, closed, log: log, brand: Pylon::Brand.new("Test Sync")).run

      log.to_s.should start_with("Test Sync: the greeting could not be sent, stopping")
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "is sent by the server before anything else" do
    root = File.join(Dir.tempdir, "pylon-greeting-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(root)

    client, socket = UNIXSocket.pair
    server = Server.new(LocalEndpoint.new(root), socket, socket, brand: Pylon::Brand::DEFAULT)
    spawn { server.run }

    begin
      identity = Bytes.new(Pylon::Wire::IDENTITY.bytesize)
      client.read_fully(identity)

      String.new(identity).should eq(Pylon::Wire::IDENTITY)
      client.read_bytes(UInt32, Pylon::Wire::FORMAT).should eq(Pylon::Wire::PROTOCOL)
    ensure
      client.close
      socket.close
      FileUtils.rm_rf(root)
    end
  end
end
