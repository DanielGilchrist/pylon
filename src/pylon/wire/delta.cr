require "digest/sha256"
require "../wire"
require "./delta/based"
require "./delta/ops_encoder"

module Pylon::Wire
  module Delta
    extend self

    alias Signatures = Hash(Bytes, Based)

    STRONG_BYTES        =   8
    MINIMUM_BLOCK       = 512
    MAXIMUM_BLOCK       = 128 * 1024
    MINIMUM_CONTENT     = 1024
    LARGEST_DELTA_FILE  = 64_u64 * 1024 * 1024
    SMALLEST_DELTA_FILE = 8_u64 * 1024

    {% if flag?(:timing) %}
      class_property deltas_sent = 0
      class_property delta_bytes = 0_i64
      class_property fulls_sent = 0
      class_property full_bytes = 0_i64

      def self.reset_tallies : Nil
        @@deltas_sent = 0
        @@delta_bytes = 0_i64
        @@fulls_sent = 0
        @@full_bytes = 0_i64
      end
    {% end %}

    def worthwhile?(size : UInt64) : Bool
      SMALLEST_DELTA_FILE <= size <= LARGEST_DELTA_FILE
    end

    def plausible_dimensions?(block_size : UInt32, base_size : UInt64) : Bool
      MINIMUM_BLOCK <= block_size <= MAXIMUM_BLOCK && base_size <= LARGEST_DELTA_FILE
    end

    def block_size_for(size : UInt64) : Int32
      root = Math.sqrt(size).to_i
      ((root + 63) // 64 * 64).clamp(MINIMUM_BLOCK, MAXIMUM_BLOCK)
    end

    def signature(content : Bytes) : Signature
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

        blocks << Block.new(weak_checksum(window), sum[0, STRONG_BYTES].dup)
        offset += length
      end

      Signature.new(block_size, content.size.to_i64, blocks)
    end

    def compute(content : Bytes, signature : Signature) : Bytes?
      return if content.size < MINIMUM_CONTENT
      return if signature.blocks.empty?

      block_size = signature.block_size
      return if block_size <= 0

      candidates = index(signature)
      encoder = OpsEncoder.new
      hasher = Digest::SHA256.new
      sum = Bytes.new(DIGEST_BYTES)
      literal_start = 0
      position = 0
      rolled = content.size >= block_size ? weak_checksum(content[0, block_size]) : 0_u32
      matched = 0_i64

      while position + block_size <= content.size
        found = match(content, position, block_size, rolled, candidates, signature, hasher, sum)

        if found
          encoder.insert(content[literal_start, position - literal_start])
          encoder.copy_from_base(found, block_size.to_i64)
          matched += block_size
          position += block_size
          literal_start = position
          rolled = weak_checksum(content[position, block_size]) if position + block_size <= content.size
        else
          departing = content[position]
          position += 1
          rolled = advance_checksum(rolled, departing, content[position + block_size - 1], block_size) if position + block_size <= content.size
        end
      end

      remainder = content[position, content.size - position]

      if (short = short_match(remainder, signature, hasher, sum))
        encoder.insert(content[literal_start, position - literal_start])
        encoder.copy_from_base(short, remainder.size.to_i64)
        matched += remainder.size
      else
        encoder.insert(content[literal_start, content.size - literal_start])
      end

      return if matched.zero?

      ops = encoder.finished
      return if ops.size >= content.size - content.size // 4

      ops
    end

    def apply(base : Bytes, ops : Bytes) : Bytes?
      io = IO::Memory.new(ops)
      rebuilt = IO::Memory.new
      written = 0_u64

      while (tag = io.read_byte)
        case tag
        when 0_u8
          return if ops.size - io.pos < 12

          offset = io.read_bytes(UInt64, FORMAT)
          length = io.read_bytes(UInt32, FORMAT).to_u64
          return if offset > base.size.to_u64 || length > base.size.to_u64 - offset

          written += length
          return if written > LARGEST_DELTA_FILE

          rebuilt.write(base[offset.to_i32, length.to_i32])
        when 1_u8
          return if ops.size - io.pos < 4

          length = io.read_bytes(UInt32, FORMAT).to_i64
          return if length > ops.size - io.pos

          written += length.to_u64
          return if written > LARGEST_DELTA_FILE

          rebuilt.write(ops[io.pos, length])
          io.pos += length
        else
          return
        end
      end

      rebuilt.to_slice
    end

    def weak_checksum(window : Bytes) : UInt32
      a = 0_u32
      b = 0_u32

      window.each do |byte|
        a &+= byte
        b &+= a
      end

      (a & 0xffff_u32) | (b << 16)
    end

    private def index(signature : Signature) : Hash(UInt32, Array(Int32))
      full_blocks = signature.full_block_count
      candidates = Hash(UInt32, Array(Int32)).new(initial_capacity: full_blocks)

      signature.blocks.each_with_index do |block, position|
        break if position >= full_blocks

        (candidates[block.weak] ||= Array(Int32).new) << position
      end

      candidates
    end

    private def match(
      content : Bytes,
      position : Int32,
      block_size : Int32,
      rolled : UInt32,
      candidates : Hash(UInt32, Array(Int32)),
      signature : Signature,
      hasher : Digest::SHA256,
      sum : Bytes,
    ) : Int64?
      indices = candidates[rolled]?
      return if indices.nil?

      window = content[position, block_size]
      hasher.reset
      hasher.update(window)
      hasher.final(sum)
      strong = sum[0, STRONG_BYTES]

      indices.each do |index|
        return index.to_i64 * block_size if signature.blocks[index].strong == strong
      end

      nil
    end

    private def short_match(
      remainder : Bytes,
      signature : Signature,
      hasher : Digest::SHA256,
      sum : Bytes,
    ) : Int64?
      return if remainder.empty?
      return if signature.short_final_size != remainder.size

      final = signature.blocks.last
      return unless weak_checksum(remainder) == final.weak

      hasher.reset
      hasher.update(remainder)
      hasher.final(sum)
      return unless sum[0, STRONG_BYTES] == final.strong

      (signature.blocks.size - 1).to_i64 * signature.block_size
    end

    private def advance_checksum(rolled : UInt32, departing : UInt8, arriving : UInt8, length : Int32) : UInt32
      a = rolled & 0xffff_u32
      b = rolled >> 16

      a = (a &- departing) & 0xffff_u32
      b = (b &- (length.to_u32 &* departing)) & 0xffff_u32

      a = (a &+ arriving) & 0xffff_u32
      b = (b &+ a) & 0xffff_u32

      (a & 0xffff_u32) | (b << 16)
    end
  end
end
