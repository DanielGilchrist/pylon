require "../../spec_helper"
require "../../../src/pylon/compress/prefix"
require "../../../src/pylon/compress/zstd"

include Pylon::Compress

private ORIGINAL = Random.new(31).random_bytes(256 * 1024)

private def edited_copy : Bytes
  edited = ORIGINAL.dup
  8.times { |offset| edited[1000 + offset] = 0xAB_u8 }
  edited
end

private def framed(prefix : Prefix, source : Bytes, base : Bytes) : Bytes
  frame = prefix.compress(source, base, Bytes.new(Zstd.bound(source.size)))
  raise "compression failed: #{frame.message}" if frame.is_a?(Error)

  frame
end

describe Pylon::Compress::Prefix do
  it "round trips content compressed against a prefix" do
    prefix = Prefix.new
    edited = edited_copy

    rebuilt = prefix.decompress(framed(prefix, edited, ORIGINAL), ORIGINAL, edited.size)

    rebuilt.should eq(edited)
  end

  it "shrinks an edit of incompressible content to a fraction of the plain frame" do
    edited = edited_copy
    codec = Zstd.new(9)
    plain = codec.compress(edited, Bytes.new(codec.bound(edited.size)))

    frame = framed(Prefix.new, edited, ORIGINAL)

    frame.size.should be < 1024
    plain.size.should be > 250 * 1024 if plain.is_a?(Bytes)
  end

  it "does not reproduce the content against a different prefix" do
    prefix = Prefix.new
    edited = edited_copy
    other = Random.new(32).random_bytes(ORIGINAL.size)

    rebuilt = prefix.decompress(framed(prefix, edited, ORIGINAL), other, edited.size)

    (rebuilt.is_a?(Error) || rebuilt != edited).should be_true
  end

  it "refuses a frame whose declared size exceeds the limit" do
    prefix = Prefix.new
    edited = edited_copy

    rebuilt = prefix.decompress(framed(prefix, edited, ORIGINAL), ORIGINAL, 1024)

    rebuilt.should be_a(Error)
    rebuilt.message.should contain("over the 1024 byte limit") if rebuilt.is_a?(Error)
  end

  it "refuses a frame that is not zstd at all" do
    rebuilt = Prefix.new.decompress(Bytes.new(16, 1_u8), ORIGINAL, 1024 * 1024)

    rebuilt.should be_a(Error)
  end
end
