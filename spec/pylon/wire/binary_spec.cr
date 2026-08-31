require "../../spec_helper"
require "../../../src/pylon/wire/binary"

include Pylon::Wire

private def round_trip_entry(entry : Entry?) : Entry?
  io = IO::Memory.new
  Binary.write_entry(io, entry)
  io.rewind
  Binary.read_entry(Reader.new(io))
end

private def fails_to_decode(bytes : Bytes, & : Reader ->) : Bool
  reader = Reader.new(IO::Memory.new(bytes))
  yield reader
  reader.failed?
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

  Pylon::Core::Directory.new(contents)
end

describe Pylon::Wire::Binary do
  it "round trips every kind of entry" do
    (round_trip_entry(nil) == nil).should be_true

    {Fixtures.f1, Fixtures.f1x, Fixtures.symlink_relative, Fixtures.untracked,
     Fixtures.problematic, Fixtures.d0, Fixtures.d1}.each do |entry|
      (round_trip_entry(entry) == entry).should be_true
    end
  end

  it "round trips a symlink target and a problem message" do
    link = round_trip_entry(Pylon::Core::SymbolicLink.new("../elsewhere"))
    link.is_a?(Pylon::Core::SymbolicLink).should be_true
    link.target.should eq("../elsewhere") if link.is_a?(Pylon::Core::SymbolicLink)

    problem = round_trip_entry(Pylon::Core::Problematic.new("permission denied"))
    problem.is_a?(Pylon::Core::Problematic).should be_true
    problem.problem.should eq("permission denied") if problem.is_a?(Pylon::Core::Problematic)
  end

  it "distinguishes an empty directory from a missing entry" do
    round_trip_entry(Pylon::Core::Directory.new).should_not be_nil
    round_trip_entry(nil).should be_nil
  end

  it "round trips arbitrary trees" do
    seed = 20260901_u64
    random = Random.new(seed)

    500.times do |iteration|
      entry = random_entry(random, 3)

      (round_trip_entry(entry) == entry).should be_true,
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

    decoded = Binary.read_changes(Reader.new(io))
    decoded.size.should eq(3)
    decoded.zip(changes) { |actual, expected| (actual == expected).should be_true }
  end

  it "round trips outcomes including the skip reason" do
    outcomes = [
      Pylon::Write::Outcome.new("ok.rb", Fixtures.f1),
      Pylon::Write::Outcome.new("bad.rb", nil, Pylon::Write::ModificationDetected.new),
      Pylon::Write::Outcome.new("worse.rb", nil, Pylon::Write::WriteFailed.new("disk full")),
    ]

    io = IO::Memory.new
    Binary.write_outcomes(io, outcomes)
    io.rewind

    decoded = Binary.read_outcomes(Reader.new(io))
    decoded[0].applied?.should be_true
    decoded[1].skipped.should eq(Pylon::Write::ModificationDetected.new)
    decoded[1].entry.should be_nil
    decoded[2].skipped.should eq(Pylon::Write::WriteFailed.new("disk full"))
  end

  it "round trips an empty byte string distinctly from a missing one" do
    io = IO::Memory.new
    Binary.write_bytes(io, Bytes.empty)
    Binary.write_bytes(io, nil)
    io.rewind

    reader = Reader.new(io)
    reader.bytes?.should eq(Bytes.empty)
    reader.bytes?.should be_nil
    reader.failed?.should be_false
  end

  it "reports a half written message as a failure rather than silently truncating it" do
    io = IO::Memory.new
    Binary.write_entry(io, Fixtures.d1)

    fails_to_decode(io.to_slice[0, 3]) { |reader| Binary.read_entry(reader) }.should be_true
  end

  it "refuses a traversing change path rather than letting it reach disk" do
    io = IO::Memory.new
    Binary.write_changes(io, [Pylon::Core::Change.new("../../etc/passwd", nil, Fixtures.f1)])

    fails_to_decode(io.to_slice) { |reader| Binary.read_changes(reader) }.should be_true
  end

  it "refuses a directory child name that is not a single component" do
    io = IO::Memory.new
    Binary.write_entry(io, Pylon::Core::Directory.new({"../escape" => Fixtures.f1}))

    fails_to_decode(io.to_slice) { |reader| Binary.read_entry(reader) }.should be_true
  end

  it "refuses a file entry whose digest is not the sha-256 width" do
    io = IO::Memory.new
    io.write_byte(2_u8)
    Binary.write_bytes(io, "short".to_slice)
    Binary.write_bool(io, false)

    fails_to_decode(io.to_slice) { |reader| Binary.read_entry(reader) }.should be_true
  end

  it "refuses a field larger than the frame limit before allocating it" do
    io = IO::Memory.new
    io.write_bytes((Pylon::Wire::MAX_FIELD_BYTES + 2).to_u32, Pylon::Wire::FORMAT)

    fails_to_decode(io.to_slice) { |reader| reader.string? }.should be_true
  end

  it "accepts a field of exactly the frame limit" do
    content = Bytes.new(Pylon::Wire::MAX_FIELD_BYTES) { 'x'.ord.to_u8 }
    io = IO::Memory.new
    Binary.write_bytes(io, content)
    io.rewind

    reader = Reader.new(io)
    reader.bytes?.should eq(content)
    reader.failed?.should be_false
  end

  it "refuses a byte that is neither 0 nor 1 where a bool was promised" do
    fails_to_decode(Bytes[2_u8]) { |reader| reader.bool }.should be_true
  end
end
