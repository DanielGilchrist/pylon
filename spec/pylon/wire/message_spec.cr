require "../../spec_helper"
require "../../../src/pylon/wire/message"

include Pylon::Wire

private def round_trip(message : Message::Any) : Message::Any | Closed | Invalid
  io = IO::Memory.new
  Message.write(io, message)
  io.rewind
  Message.read(io)
end

private def configuration(root : String = "/srv/app", brand : String = "Test Sync", state : String? = "/srv/.state") : Message::Configure
  Message::Configure.new(
    root: root,
    ignores: ["node_modules", ".git"],
    compression: 9,
    brand: Pylon::Brand.new(brand),
    state: state,
    watch: true,
  )
end

describe Pylon::Wire::Message::Configure do
  it "round trips everything the client decides for the remote end" do
    received = round_trip(configuration)

    received.should be_a(Message::Configure)
    next unless received.is_a?(Message::Configure)

    received.root.should eq("/srv/app")
    received.ignores.should eq(["node_modules", ".git"])
    received.compression.should eq(9)
    received.brand.should eq(Pylon::Brand.new("Test Sync"))
    received.state.should eq("/srv/.state")
    received.watch?.should be_true
  end

  it "keeps having no state path distinct from an empty one" do
    received = round_trip(configuration(state: nil))

    received.should be_a(Message::Configure)
    received.state.should be_nil if received.is_a?(Message::Configure)
  end

  it "refuses a blank brand" do
    received = round_trip(configuration(brand: "  "))

    received.should be_a(Invalid)
    received.reason.should contain("blank") if received.is_a?(Invalid)
  end

  it "refuses an empty root" do
    received = round_trip(configuration(root: ""))

    received.should be_a(Invalid)
    received.reason.should contain("root") if received.is_a?(Invalid)
  end

  it "refuses a NUL byte in a path before it can reach a syscall" do
    received = round_trip(configuration(root: "/srv/app\0"))

    received.should be_a(Invalid)
    received.reason.should eq("a string in the message contains a NUL byte") if received.is_a?(Invalid)
  end
end
