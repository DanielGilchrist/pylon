require "../../spec_helper"
require "../../../src/pylon/wire/message"

private alias Any = Pylon::Wire::Message::Any
private alias Brand = Pylon::Brand
private alias Configure = Pylon::Wire::Message::Configure
private DIGEST_BYTES = Pylon::Wire::DIGEST_BYTES
private alias Message = Pylon::Wire::Message
private alias Problem = Pylon::Problem
private alias ReusableRequest = Pylon::Wire::Message::ReusableRequest
private alias ReusableResponse = Pylon::Wire::Message::ReusableResponse
private alias ScanProgress = Pylon::Wire::Message::ScanProgress
private alias TreeAnnounce = Pylon::Wire::Message::TreeAnnounce
private alias TreeChanges = Pylon::Wire::Message::TreeChanges
private alias TreeUpdate = Pylon::Wire::Message::TreeUpdate

private def round_trip(message : Any) : Any | Pylon::Wire::Closed | Problem
  io = IO::Memory.new
  Message.write(io, message)
  io.rewind
  Message.read(io)
end

private def configuration(
  root : String = "/srv/app",
  brand : String = "Test Sync",
  state : String? = "/srv/.state",
  tree_fingerprint : Bytes? = nil,
) : Configure
  Configure.new(
    root: root,
    ignores: ["node_modules", ".git"],
    compression: 9,
    brand: Brand.new(brand),
    state: state,
    watch: true,
    tree_fingerprint: tree_fingerprint,
  )
end

describe ReusableRequest do
  it "round trips the digests the sender would otherwise send in full" do
    digests = [Bytes.new(DIGEST_BYTES, 1_u8), Bytes.new(DIGEST_BYTES, 2_u8)]
    received = round_trip(ReusableRequest.new(digests))

    received.should be_a(ReusableRequest)
    received.digests.should eq(digests) if received.is_a?(ReusableRequest)
  end
end

describe ReusableResponse do
  it "round trips the digests the receiver can recover itself" do
    received = round_trip(ReusableResponse.new([Bytes.new(DIGEST_BYTES, 3_u8)]))

    received.should be_a(ReusableResponse)
    if received.is_a?(ReusableResponse)
      received.payload.should eq([Bytes.new(DIGEST_BYTES, 3_u8)])
    end
  end
end

describe TreeChanges do
  it "round trips the changes since the tree the client already holds" do
    changes = Pylon::Core::Changes[Pylon::Core::Change.new("a.rb", Fixtures.f1, Fixtures.f2)]
    received = round_trip(TreeChanges.new(4_u32, changes, live: true))

    received.should be_a(TreeChanges)
    next unless received.is_a?(TreeChanges)

    received.sequence.should eq(4_u32)
    received.live?.should be_true
    received.changes.size.should eq(1)
    received.changes[0].path.should eq("a.rb")
    (received.changes[0].new == Fixtures.f2).should be_true
  end
end

describe TreeUpdate do
  it "round trips a live tree the server will keep updating" do
    root = Pylon::Core::Directory.new(
      {"a.rb" => Pylon::Core::File.new(Bytes.new(DIGEST_BYTES, 7_u8), executable: false)},
    )
    received = round_trip(TreeUpdate.new(3_u32, root, live: true))

    received.should be_a(TreeUpdate)
    next unless received.is_a?(TreeUpdate)

    received.sequence.should eq(3_u32)
    received.root.should eq(root)
    received.live?.should be_true
  end

  it "round trips a one-off tree from a server that cannot watch" do
    received = round_trip(TreeUpdate.new(1_u32, nil, live: false))

    received.should be_a(TreeUpdate)
    next unless received.is_a?(TreeUpdate)

    received.root.should be_nil
    received.live?.should be_false
  end
end

describe ScanProgress do
  it "round trips the remote scan's counters" do
    received = round_trip(ScanProgress.new(12_400_i64, 325_000_000_i64))

    received.should be_a(ScanProgress)
    next unless received.is_a?(ScanProgress)

    received.files.should eq(12_400_i64)
    received.bytes.should eq(325_000_000_i64)
  end
end

describe TreeAnnounce do
  it "round trips the size of the tree about to follow" do
    received = round_trip(TreeAnnounce.new(1_314_000_u32))

    received.should be_a(TreeAnnounce)
    received.bytes.should eq(1_314_000_u32) if received.is_a?(TreeAnnounce)
  end
end

describe Configure do
  it "round trips everything the client decides for the remote end" do
    received = round_trip(configuration)

    received.should be_a(Configure)
    next unless received.is_a?(Configure)

    received.root.should eq("/srv/app")
    received.ignores.should eq(["node_modules", ".git"])
    received.compression.should eq(9)
    received.brand.should eq(Brand.new("Test Sync"))
    received.state.should eq("/srv/.state")
    received.watch?.should be_true
  end

  it "round trips the fingerprint of the tree the client already holds" do
    fingerprint = Bytes.new(DIGEST_BYTES, 9_u8)
    received = round_trip(configuration(tree_fingerprint: fingerprint))

    received.should be_a(Configure)
    received.tree_fingerprint.should eq(fingerprint) if received.is_a?(Configure)
  end

  it "refuses a fingerprint of the wrong length" do
    received = round_trip(configuration(tree_fingerprint: Bytes.new(5, 9_u8)))

    received.should be_a(Problem)
    received.reason.should contain("fingerprint") if received.is_a?(Problem)
  end

  it "keeps having no state path distinct from an empty one" do
    received = round_trip(configuration(state: nil))

    received.should be_a(Configure)
    received.state.should be_nil if received.is_a?(Configure)
  end

  it "refuses a blank brand" do
    received = round_trip(configuration(brand: "  "))

    received.should be_a(Problem)
    received.reason.should contain("blank") if received.is_a?(Problem)
  end

  it "refuses an empty root" do
    received = round_trip(configuration(root: ""))

    received.should be_a(Problem)
    received.reason.should contain("root") if received.is_a?(Problem)
  end

  it "refuses a NUL byte in a path before it can reach a syscall" do
    received = round_trip(configuration(root: "/srv/app\0"))

    received.should be_a(Problem)
    if received.is_a?(Problem)
      received.reason.should eq("a string in the message contains a NUL byte")
    end
  end
end
