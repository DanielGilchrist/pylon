require "digest/sha256"

module Pylon::Wire
  struct Checksums
    STRONG_BYTES  =   8
    MINIMUM_BLOCK = 512
    MAXIMUM_BLOCK = 128 * 1024

    alias Map = Hash(Bytes, Checksums)

    def self.of(base : Bytes, content : Bytes) : Checksums
      block_size = block_size_for(content.size.to_u64)
      blocks = Array(Block).new((content.size + block_size - 1) // block_size)
      hasher = Digest::SHA256.new
      sum = Bytes.new(DIGEST_BYTES)
      offset = 0

      while offset < content.size
        length = Math.min(block_size, content.size - offset)
        window = content[offset, length]

        hasher.reset
        hasher.update(window)
        hasher.final(sum)

        blocks << Block.new(weak(window), sum[0, STRONG_BYTES].dup)
        offset += length
      end

      new(base, block_size, content.size.to_i64, blocks)
    end

    def self.block_size_for(size : UInt64) : Int32
      root = Math.sqrt(size).to_i
      ((root + 63) // 64 * 64).clamp(MINIMUM_BLOCK, MAXIMUM_BLOCK)
    end

    def self.plausible?(block_size : UInt32, base_size : UInt64) : Bool
      MINIMUM_BLOCK <= block_size <= MAXIMUM_BLOCK && base_size <= Splice::LARGEST_FILE
    end

    def self.weak(window : Bytes) : UInt32
      a = 0_u32
      b = 0_u32

      window.each do |byte|
        a &+= byte
        b &+= a
      end

      (a & 0xffff_u32) | (b << 16)
    end

    def initialize(
      @base : Bytes,
      @block_size : Int32,
      @base_size : Int64,
      @blocks : Array(Block),
    ) : Nil
    end

    getter base : Bytes
    getter block_size : Int32
    getter base_size : Int64
    getter blocks : Array(Block)

    def full_block_count : Int32
      (base_size // block_size).to_i32
    end

    def short_final_size : Int32
      (base_size % block_size).to_i32
    end
  end
end
