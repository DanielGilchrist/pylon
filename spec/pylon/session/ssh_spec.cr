require "../../spec_helper"
require "../../../src/pylon/session/process_transport"
require "../../../src/pylon/session/ssh"

include Pylon::Session

describe Pylon::Session::Ssh do
  it "builds a minimal command" do
    Ssh.command(host: "user@host", remote_command: "pylon server /srv/app")
      .should eq(["-q", "user@host", "pylon server /srv/app"])
  end

  it "puts options before the host, where every ssh accepts them" do
    arguments = Ssh.command(
      host: "user@host",
      remote_command: "pylon server /srv/app",
      config: "/home/me/.ssh/example_ssh_config",
      port: "2222",
    )

    arguments.should eq([
      "-q",
      "-F", "/home/me/.ssh/example_ssh_config",
      "-p", "2222",
      "user@host",
      "pylon server /srv/app",
    ])

    arguments.index("user@host").not_nil!.should be > arguments.index("-p").not_nil!
  end

  it "omits flags that were not asked for" do
    Ssh.command(host: "h", remote_command: "c", port: "22")
      .should eq(["-q", "-p", "22", "h", "c"])
  end
end

describe Pylon::Session::ProcessTransport do
  it "carries bytes to a child process and back" do
    transport = ProcessTransport.open("cat", [] of String)

    transport.writer.puts("hello over the pipe")
    transport.writer.flush
    transport.reader.gets.should eq("hello over the pipe")

    transport.close.success?.should be_true
  end

  it "reports the child's exit status" do
    transport = ProcessTransport.open("sh", ["-c", "exit 3"])

    transport.close.exit_code.should eq(3)
  end
end
