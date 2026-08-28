require "../../spec_helper"
require "../../../src/pylon/wire/binary"

include Pylon::Wire

private def round_trip_entry(entry : Entry?) : Entry?
  io = IO::Memory.new
  Binary.write_entry(io, entry)
  io.rewind
  Binary.read_entry(io)
end

private CONTENTS = {nil, Fixtures.f1, Fixtures.f2, Fixtures.f1x, Fixtures.untracked, Fixtures.problematic}
private NAMES    = {"a", "b", "c"}

private def random_entry(random : Random, depth : Int32) : Entry?
  if depth <= 0 || random.rand(3) == 0
    return CONTENTS[random.rand(CONTENTS.size)]
  end

  contents = {} of String => Entry
  NAMES.each do |name|
    if (child = random_entry(random, depth - 1))
      contents[name] = child
    end
  end

  Entry.directory(contents)
end

describe Pylon::Wire::Binary do
  it "round trips every kind of entry" do
    Entry.equal?(round_trip_entry(nil), nil).should be_true

    {Fixtures.f1, Fixtures.f1x, Fixtures.symlink_relative, Fixtures.untracked,
     Fixtures.problematic, Fixtures.d0, Fixtures.d1}.each do |entry|
      Entry.equal?(round_trip_entry(entry), entry).should be_true
    end
  end

  it "round trips a symlink target and a problem message" do
    round_trip_entry(Entry.symlink("../elsewhere")).not_nil!.target.should eq("../elsewhere")
    round_trip_entry(Entry.problematic("permission denied")).not_nil!.problem.should eq("permission denied")
  end

  it "distinguishes an empty directory from a missing entry" do
    round_trip_entry(Entry.directory).should_not be_nil
    round_trip_entry(nil).should be_nil
  end

  it "round trips arbitrary trees" do
    seed = 20260901_u64
    random = Random.new(seed)

    500.times do |iteration|
      entry = random_entry(random, 3)

      Entry.equal?(round_trip_entry(entry), entry).should be_true,
        "seed=#{seed} iteration=#{iteration}"
    end
  end

  it "round trips changes" do
    changes = [
      Change.new("a.rb", nil, Fixtures.f1),
      Change.new("b/c.rb", Fixtures.f1, nil),
      Change.new("", Fixtures.d0, Fixtures.d1),
    ]

    io = IO::Memory.new
    Binary.write_changes(io, changes)
    io.rewind

    decoded = Binary.read_changes(io)
    decoded.size.should eq(3)
    decoded.zip(changes) { |actual, expected| (actual == expected).should be_true }
  end

  it "round trips outcomes including the skip reason" do
    outcomes = [
      Pylon::Write::Outcome.new("ok.rb", Fixtures.f1),
      Pylon::Write::Outcome.new("bad.rb", nil, Pylon::Write::Skipped::ModificationDetected),
    ]

    io = IO::Memory.new
    Binary.write_outcomes(io, outcomes)
    io.rewind

    decoded = Binary.read_outcomes(io)
    decoded[0].applied?.should be_true
    decoded[1].skipped.should eq(Pylon::Write::Skipped::ModificationDetected)
    decoded[1].entry.should be_nil
  end

  it "round trips an empty byte string distinctly from a missing one" do
    io = IO::Memory.new
    Binary.write_bytes(io, Bytes.empty)
    Binary.write_bytes(io, nil)
    io.rewind

    Binary.read_bytes(io).should eq(Bytes.empty)
    Binary.read_bytes(io).should be_nil
  end

  it "raises rather than silently truncating a half written message" do
    io = IO::Memory.new
    Binary.write_entry(io, Fixtures.d1)
    truncated = IO::Memory.new(io.to_slice[0, 3])

    expect_raises(Pylon::Wire::Truncated) do
      Binary.read_entry(truncated)
    end
  end
end
