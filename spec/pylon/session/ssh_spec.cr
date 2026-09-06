require "../../spec_helper"
require "../../../src/pylon/session/process_transport"
require "../../../src/pylon/session/ssh"

private alias Problem = Pylon::Problem
private alias ProcessTransport = Pylon::Session::ProcessTransport
private SSH = Pylon::Session::SSH

describe SSH do
  it "builds a minimal command" do
    SSH.command(host: "user@host", remote_command: "pylon server /srv/app", config: nil, port: nil)
      .should eq(["user@host", "pylon server /srv/app"])
  end

  it "puts options before the host, where every ssh accepts them" do
    arguments = SSH.command(
      host: "user@host",
      remote_command: "pylon server /srv/app",
      config: "/home/me/.ssh/example_ssh_config",
      port: "2222",
    )

    arguments.should eq([
      "-F", "/home/me/.ssh/example_ssh_config",
      "-p", "2222",
      "user@host",
      "pylon server /srv/app",
    ])

    arguments.index!("user@host").should be > arguments.index!("-p")
  end

  it "omits flags that were not asked for" do
    SSH.command(host: "h", remote_command: "c", config: nil, port: "22")
      .should eq(["-p", "22", "h", "c"])
  end
end

private def opened(command : String, arguments : Array(String)) : ProcessTransport
  case (transport = ProcessTransport.open(command, arguments) { })
  in Problem          then fail(transport.reason)
  in ProcessTransport then transport
  end
end

describe ProcessTransport do
  it "carries bytes to a child process and back" do
    transport = opened("cat", Array(String).new)

    transport.writer.puts("hello over the pipe")
    transport.writer.flush
    transport.reader.gets.should eq("hello over the pipe")

    transport.close.success?.should be_true
  end

  it "reports the child's exit status" do
    transport = opened("sh", ["-c", "exit 3"])

    transport.close.exit_code.should eq(3)
  end

  it "relays the child's error output line by line" do
    lines = Channel(String).new(4)
    transport = ProcessTransport.open("sh", ["-c", "echo one >&2; echo two >&2"]) do |line|
      lines.send(line)
    end

    fail(transport.reason) if transport.is_a?(Problem)

    lines.receive.should eq("one")
    lines.receive.should eq("two")
    transport.close.success?.should be_true
  end

  it "reports a command that cannot be started instead of raising" do
    opened = ProcessTransport.open("pylon-no-such-binary", Array(String).new) { }

    fail("expected a problem, got a transport") unless opened.is_a?(Problem)
    opened.reason.should contain("pylon-no-such-binary could not be started")
  end
end
