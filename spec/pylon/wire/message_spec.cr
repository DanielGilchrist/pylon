require "../../spec_helper"
require "../../../src/pylon/wire/message"

include Pylon::Wire

private def round_trip(message : Message::Any) : Message::Any | Closed | Invalid
  io = IO::Memory.new
  Message.write(io, message)
  io.rewind
  Message.read(io)
end

private def configuration(root : String = "/srv/app", brand : String = "Test Sync", state : String? = "/srv/.state", known : Bytes? = nil) : Message::Configure
  Message::Configure.new(
    root: root,
    ignores: ["node_modules", ".git"],
    compression: 9,
    brand: Pylon::Brand.new(brand),
    state: state,
    watch: true,
    known: known,
  )
end

describe Pylon::Wire::Message::AvailabilityRequest do
  it "round trips the digests the sender would otherwise ship in full" do
    digests = [Bytes.new(DIGEST_BYTES, 1_u8), Bytes.new(DIGEST_BYTES, 2_u8)]
    received = round_trip(Message::AvailabilityRequest.new(digests))

    received.should be_a(Message::AvailabilityRequest)
    received.digests.should eq(digests) if received.is_a?(Message::AvailabilityRequest)
  end
end

describe Pylon::Wire::Message::AvailabilityResponse do
  it "round trips the digests the receiver can recover itself" do
    received = round_trip(Message::AvailabilityResponse.new([Bytes.new(DIGEST_BYTES, 3_u8)]))

    received.should be_a(Message::AvailabilityResponse)
    received.payload.should eq([Bytes.new(DIGEST_BYTES, 3_u8)]) if received.is_a?(Message::AvailabilityResponse)
  end
end

describe Pylon::Wire::Message::TreeDelta do
  it "round trips the changes since the tree the client already holds" do
    changes = Pylon::Core::Changes[Pylon::Core::Change.new("a.rb", Fixtures.f1, Fixtures.f2)]
    received = round_trip(Message::TreeDelta.new(4_u32, changes, live: true))

    received.should be_a(Message::TreeDelta)
    next unless received.is_a?(Message::TreeDelta)

    received.sequence.should eq(4_u32)
    received.live?.should be_true
    received.changes.size.should eq(1)
    received.changes[0].path.should eq("a.rb")
    (received.changes[0].new == Fixtures.f2).should be_true
  end
end

describe Pylon::Wire::Message::TreeUpdate do
  it "round trips a live tree the server will keep updating" do
    root = Pylon::Core::Directory.new({"a.rb" => Pylon::Core::File.new(Bytes.new(DIGEST_BYTES, 7_u8), executable: false)})
    received = round_trip(Message::TreeUpdate.new(3_u32, root, live: true))

    received.should be_a(Message::TreeUpdate)
    next unless received.is_a?(Message::TreeUpdate)

    received.sequence.should eq(3_u32)
    received.root.should eq(root)
    received.live?.should be_true
  end

  it "round trips a one-off tree from a server that cannot watch" do
    received = round_trip(Message::TreeUpdate.new(1_u32, nil, live: false))

    received.should be_a(Message::TreeUpdate)
    next unless received.is_a?(Message::TreeUpdate)

    received.root.should be_nil
    received.live?.should be_false
  end
end

describe Pylon::Wire::Message::ScanProgress do
  it "round trips the remote scan's counters" do
    received = round_trip(Message::ScanProgress.new(12_400_i64, 325_000_000_i64))

    received.should be_a(Message::ScanProgress)
    next unless received.is_a?(Message::ScanProgress)

    received.files.should eq(12_400_i64)
    received.hashed_bytes.should eq(325_000_000_i64)
  end
end

describe Pylon::Wire::Message::TreeAnnounce do
  it "round trips the size of the tree about to follow" do
    received = round_trip(Message::TreeAnnounce.new(1_314_000_u32))

    received.should be_a(Message::TreeAnnounce)
    received.bytes.should eq(1_314_000_u32) if received.is_a?(Message::TreeAnnounce)
  end
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

  it "round trips the fingerprint of the tree the client already holds" do
    known = Bytes.new(DIGEST_BYTES, 9_u8)
    received = round_trip(configuration(known: known))

    received.should be_a(Message::Configure)
    received.known.should eq(known) if received.is_a?(Message::Configure)
  end

  it "refuses a fingerprint of the wrong length" do
    received = round_trip(configuration(known: Bytes.new(5, 9_u8)))

    received.should be_a(Invalid)
    received.reason.should contain("fingerprint") if received.is_a?(Invalid)
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
