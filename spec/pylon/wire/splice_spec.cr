require "../../spec_helper"

private alias Checksums = Pylon::Wire::Checksums
private FORMAT = Pylon::Wire::FORMAT
private alias Splice = Pylon::Wire::Splice

private def roundtrip(base : Bytes, edited : Bytes) : Bytes?
  checksums = Checksums.of(Bytes.new(32), base)
  ops = Splice.plan(edited, checksums)
  return if ops.nil?

  Splice.apply(base, ops)
end

private def source_like(size : Int32, seed : UInt64) : Bytes
  random = Random.new(seed)
  words = %w[def end class module require include return property getter struct]
  builder = String::Builder.new

  while builder.bytesize < size
    builder << words[random.rand(words.size)] << " item" << random.rand(10_000) << "\n"
  end

  builder.to_s.to_slice
end

describe Splice do
  it "rolls the weak hash to the same value a fresh computation gives" do
    content = source_like(4096, 3_u64)

    full = Checksums.weak(content[1, 512])
    hand_rolled = Checksums.weak(content[0, 512])
    a = hand_rolled & 0xffff_u32
    b = hand_rolled >> 16
    a = (a &- content[0]) & 0xffff_u32
    b = (b &- (512_u32 &* content[0])) & 0xffff_u32
    a = (a &+ content[512]) & 0xffff_u32
    b = (b &+ a) & 0xffff_u32

    ((a & 0xffff_u32) | (b << 16)).should eq(full)
  end

  it "reconstructs an appended file from a few bytes of ops" do
    base = source_like(40_000, 1_u64)
    appended = "record appended_line\n".to_slice
    edited = Bytes.new(base.size + appended.size)
    base.copy_to(edited)
    appended.copy_to(edited[base.size, appended.size])

    checksums = Checksums.of(Bytes.new(32), base)
    ops = Splice.plan(edited, checksums)

    ops.should_not be_nil
    ops.as(Bytes).size.should be < 1024
    Splice.apply(base, ops.as(Bytes)).should eq(edited)
  end

  it "reconstructs an edit in the middle of the file" do
    base = source_like(50_000, 2_u64)
    edited = IO::Memory.new
    edited.write(base[0, 20_000])
    edited << "a replacement line\n"
    edited.write(base[20_100, base.size - 20_100])

    roundtrip(base, edited.to_slice).should eq(edited.to_slice)
  end

  it "reconstructs a prepended file" do
    base = source_like(30_000, 4_u64)
    edited = IO::Memory.new
    edited << "a fresh first line\n"
    edited.write(base)

    roundtrip(base, edited.to_slice).should eq(edited.to_slice)
  end

  it "gives up when nothing matches" do
    base = source_like(20_000, 5_u64)
    unrelated = Random.new(6).random_bytes(20_000)

    checksums = Checksums.of(Bytes.new(32), base)
    Splice.plan(unrelated, checksums).should be_nil
  end

  it "gives up on content too small to be worth splicing" do
    base = source_like(4096, 7_u64)

    checksums = Checksums.of(Bytes.new(32), base)
    Splice.plan(base[0, 512], checksums).should be_nil
  end

  it "matches the short final block of the base" do
    base = source_like(10_000, 8_u64)
    edited = IO::Memory.new
    edited << "a fresh first line\n"
    edited.write(base)

    roundtrip(base, edited.to_slice).should eq(edited.to_slice)
  end

  it "refuses ops that copy beyond the base" do
    base = source_like(2048, 9_u64)
    ops = IO::Memory.new
    ops.write_byte(0_u8)
    ops.write_bytes(2000_u64, FORMAT)
    ops.write_bytes(500_u32, FORMAT)

    Splice.apply(base, ops.to_slice).should be_nil
  end

  it "refuses truncated ops" do
    base = source_like(2048, 10_u64)
    ops = Bytes[1_u8, 255_u8, 0_u8]

    Splice.apply(base, ops).should be_nil
  end

  it "refuses an impossible copy offset without raising" do
    base = source_like(2048, 12_u64)
    ops = IO::Memory.new
    ops.write_byte(0_u8)
    ops.write_bytes(UInt64::MAX, FORMAT)
    ops.write_bytes(10_u32, FORMAT)

    Splice.apply(base, ops.to_slice).should be_nil
  end

  it "refuses ops that would rebuild more than the largest spliceable file" do
    base = Bytes.new(64 * 1024)
    repeats = (Pylon::Wire::Splice::LARGEST_FILE // base.size) + 1
    ops = IO::Memory.new

    (repeats + 1).times do
      ops.write_byte(0_u8)
      ops.write_bytes(0_u64, FORMAT)
      ops.write_bytes(base.size.to_u32, FORMAT)
    end

    Splice.apply(base, ops.to_slice).should be_nil
  end

  it "reconstructs identical content as one copy run" do
    base = source_like(100_000, 11_u64)

    checksums = Checksums.of(Bytes.new(32), base)
    ops = Splice.plan(base, checksums)

    ops.should_not be_nil
    ops.as(Bytes).size.should be < 64
    Splice.apply(base, ops.as(Bytes)).should eq(base)
  end
end
