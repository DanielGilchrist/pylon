require "../../../spec_helper"

private alias Kept = Pylon::Session::ContentStore::Kept
private alias Locations = Pylon::Session::Locations

private STALE  = Bytes.new(32, 1_u8)
private WANTED = Bytes.new(32, 2_u8)
private FRESH  = Bytes.new(32, 3_u8)

private def kept(*digests : Bytes) : Kept
  keeping = Kept.new
  digests.each { |digest| keeping.add(digest) }
  keeping
end

private def live(*digests : Bytes) : Locations
  locations = Locations.new
  digests.each_with_index { |digest, index| locations.remember(digest, "f#{index}", 0_u64) }
  locations
end

describe Kept do
  it "holds a digest once however many times it is kept" do
    keeping = kept(STALE, STALE, WANTED)

    keeping.surplus(Locations.new, bound: 0).should eq([STALE, WANTED])
  end

  it "forgets a batch from its order as well as its membership" do
    keeping = kept(STALE, WANTED, FRESH)
    keeping.delete_all([STALE, FRESH])

    keeping.includes?(STALE).should be_false
    keeping.surplus(Locations.new, bound: 0).should eq([WANTED])
  end

  it "names the oldest copies the tree no longer points at" do
    kept(STALE, WANTED, FRESH).surplus(live(WANTED), bound: 1).should eq([STALE])
  end

  it "names nothing while it holds no more than the bound" do
    kept(STALE, WANTED, FRESH).surplus(live(WANTED), bound: 3).should be_empty
  end

  it "counts a copy the tree still points at against neither the bound nor the surplus" do
    kept(STALE, WANTED, FRESH).surplus(live(STALE, WANTED, FRESH), bound: 1).should be_empty
  end

  it "comes back to the bound rather than emptying itself" do
    kept(STALE, WANTED, FRESH).surplus(Locations.new, bound: 1).should eq([STALE, WANTED])
  end
end
