require "../../../spec_helper"

private alias Checksums = Pylon::Wire::Checksums
private alias Index = Pylon::Wire::Splice::Index

private def repeated_block_checksums : Checksums
  block = Bytes.new(512) { |offset| (offset % 251).to_u8 }
  base = Bytes.new(block.size * 40) { |offset| block[offset % block.size] }

  Checksums.of(Bytes.new(32), base)
end

describe Index do
  it "offers every block that shares a weak checksum" do
    checksums = repeated_block_checksums
    index = Index.of(checksums, 1024)
    offered = 0

    index.each_candidate(checksums.blocks.first.weak) { offered += 1 }

    checksums.blocks.size.should eq(40)
    offered.should eq(40)
  end

  it "stops offering blocks once it has walked as far as it was allowed" do
    checksums = repeated_block_checksums
    index = Index.of(checksums, 2)
    offered = 0

    index.each_candidate(checksums.blocks.first.weak) { offered += 1 }

    offered.should eq(2)
  end

  it "offers nothing for a checksum no block carries" do
    checksums = repeated_block_checksums
    index = Index.of(checksums, 1024)
    offered = 0

    index.each_candidate(checksums.blocks.first.weak &+ 1) { offered += 1 }

    offered.should eq(0)
  end
end
