require "../../spec_helper"

private alias Identity = Pylon::Compress::Identity
private alias Problem = Pylon::Problem
private alias Zstd = Pylon::Compress::Zstd

private RUBY = <<-SOURCE
  # typed: strict
  class Payslip < ApplicationRecord
    belongs_to :user
    has_many :payslip_lines
  end
  SOURCE

private def round_trip(codec : Pylon::Compress::Codec, source : Bytes) : Bytes
  packed = codec.compress(source, Bytes.new(codec.bound(source.size)))
  packed.should be_a(Bytes)
  return Bytes.empty unless packed.is_a?(Bytes)

  unpacked = codec.decompress(packed, Bytes.new(source.size))
  unpacked.should be_a(Bytes)
  unpacked.is_a?(Bytes) ? unpacked : Bytes.empty
end

describe Zstd do
  it "round trips text" do
    source = (RUBY * 40).to_slice

    round_trip(Zstd.new, source).should eq(source)
  end

  it "round trips an empty slice" do
    round_trip(Zstd.new, Bytes.empty).should eq(Bytes.empty)
  end

  it "round trips bytes that do not compress" do
    random = Random.new(1234)
    source = Bytes.new(64 * 1024) { random.rand(256).to_u8 }

    round_trip(Zstd.new, source).should eq(source)
  end

  it "actually shrinks source code" do
    codec = Zstd.new
    source = (RUBY * 40).to_slice
    packed = codec.compress(source, Bytes.new(codec.bound(source.size)))

    packed.should be_a(Bytes)
    next unless packed.is_a?(Bytes)

    packed.size.should be < source.size // 4
  end

  it "reports an error rather than corrupting when the buffer is too small" do
    Zstd.new.compress((RUBY * 40).to_slice, Bytes.new(4)).should be_a(Problem)
  end

  it "reports an error for a corrupt frame" do
    garbage = "not a zstd frame at all".to_slice
    Zstd.new.decompress(garbage, Bytes.new(1024)).should be_a(Problem)
  end
end

describe Identity do
  it "round trips unchanged" do
    source = RUBY.to_slice

    round_trip(Identity.new, source).should eq(source)
  end

  it "reports an error rather than overflowing" do
    Identity.new.compress(RUBY.to_slice, Bytes.new(2)).should be_a(Problem)
  end
end
