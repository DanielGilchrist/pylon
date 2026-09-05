require "../../spec_helper"
require "../../../src/pylon/compress/dictionary"
require "../../../src/pylon/compress/zstd"

include Pylon::Compress

private ORIGINAL = Random.new(31).random_bytes(256 * 1024)

private def edited_copy : Bytes
  edited = ORIGINAL.dup
  8.times { |offset| edited[1000 + offset] = 0xAB_u8 }
  edited
end

private def framed(dictionary : Compress::Dictionary, source : Bytes, base : Bytes) : Bytes
  frame = dictionary.compress(source, base, Bytes.new(Zstd.bound(source.size)))
  raise "compression failed: #{frame.reason}" if frame.is_a?(Pylon::Problem)

  frame
end

describe Pylon::Compress::Dictionary do
  it "round trips content compressed against a dictionary" do
    dictionary = Compress::Dictionary.new
    edited = edited_copy

    rebuilt = dictionary.decompress(framed(dictionary, edited, ORIGINAL), ORIGINAL, edited.size)

    rebuilt.should eq(edited)
  end

  it "shrinks an edit of incompressible content to a fraction of the plain frame" do
    edited = edited_copy
    codec = Zstd.new(9)
    plain = codec.compress(edited, Bytes.new(codec.bound(edited.size)))

    frame = framed(Compress::Dictionary.new, edited, ORIGINAL)

    frame.size.should be < 1024
    plain.size.should be > 250 * 1024 if plain.is_a?(Bytes)
  end

  it "does not reproduce the content against a different dictionary" do
    dictionary = Compress::Dictionary.new
    edited = edited_copy
    other = Random.new(32).random_bytes(ORIGINAL.size)

    rebuilt = dictionary.decompress(framed(dictionary, edited, ORIGINAL), other, edited.size)

    (rebuilt.is_a?(Pylon::Problem) || rebuilt != edited).should be_true
  end

  it "refuses a frame whose declared size exceeds the limit" do
    dictionary = Compress::Dictionary.new
    edited = edited_copy

    rebuilt = dictionary.decompress(framed(dictionary, edited, ORIGINAL), ORIGINAL, 1024)

    rebuilt.should be_a(Pylon::Problem)
    rebuilt.reason.should contain("over the 1024 byte limit") if rebuilt.is_a?(Pylon::Problem)
  end

  it "refuses a frame that is not zstd at all" do
    rebuilt = Compress::Dictionary.new.decompress(Bytes.new(16, 1_u8), ORIGINAL, 1024 * 1024)

    rebuilt.should be_a(Pylon::Problem)
  end
end
