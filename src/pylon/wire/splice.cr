require "digest/sha256"

module Pylon::Wire
  module Splice
    extend self

    LONGEST_WALK    = 1024
    MINIMUM_CONTENT = 1024
    LARGEST_FILE    = 64_u64 * 1024 * 1024
    SMALLEST_FILE   = 8_u64 * 1024

    {% if flag?(:timing) %}
      class_property splices_sent = 0
      class_property splice_bytes = 0_i64
      class_property fulls_sent = 0
      class_property full_bytes = 0_i64
      class_property dictionaries_sent = 0
      class_property dictionary_bytes = 0_i64

      def self.reset_tallies : Nil
        @@splices_sent = 0
        @@splice_bytes = 0_i64
        @@fulls_sent = 0
        @@full_bytes = 0_i64
        @@dictionaries_sent = 0
        @@dictionary_bytes = 0_i64
      end
    {% end %}

    def worthwhile?(size : UInt64) : Bool
      SMALLEST_FILE <= size <= LARGEST_FILE
    end

    def plan(content : Bytes, checksums : Checksums) : Bytes?
      return if content.size < MINIMUM_CONTENT
      return if checksums.blocks.empty?

      block_size = checksums.block_size
      return if block_size <= 0

      index = Index.of(checksums, LONGEST_WALK)
      encoder = Encoder.new
      hasher = Digest::SHA256.new
      sum = Bytes.new(DIGEST_BYTES)
      literal_start = 0
      position = 0
      rolled = content.size >= block_size ? Checksums.weak(content[0, block_size]) : 0_u32
      matched = 0_i64

      while position + block_size <= content.size
        found = match(content, position, block_size, rolled, index, checksums, hasher, sum)

        if found
          encoder.insert(content[literal_start, position - literal_start])
          encoder.copy_from_base(found, block_size.to_i64)
          matched += block_size
          position += block_size
          literal_start = position
          if position + block_size <= content.size
            rolled = Checksums.weak(content[position, block_size])
          end
        else
          departing = content[position]
          position += 1
          if position + block_size <= content.size
            arriving = content[position + block_size - 1]
            rolled = advance_checksum(rolled, departing, arriving, block_size)
          end
        end
      end

      remainder = content[position, content.size - position]

      if (short = short_match(remainder, checksums, hasher, sum))
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
          return if written > LARGEST_FILE

          rebuilt.write(base[offset.to_i32, length.to_i32])
        when 1_u8
          return if ops.size - io.pos < 4

          length = io.read_bytes(UInt32, FORMAT).to_i64
          return if length > ops.size - io.pos

          written += length.to_u64
          return if written > LARGEST_FILE

          rebuilt.write(ops[io.pos, length])
          io.pos += length
        else
          return
        end
      end

      rebuilt.to_slice
    end

    private def match(
      content : Bytes,
      position : Int32,
      block_size : Int32,
      rolled : UInt32,
      index : Index,
      checksums : Checksums,
      hasher : Digest::SHA256,
      sum : Bytes,
    ) : Int64?
      found = nil
      strong = nil

      index.each_candidate(rolled) do |candidate|
        if strong.nil?
          window = content[position, block_size]
          hasher.reset
          hasher.update(window)
          hasher.final(sum)
          strong = sum[0, Checksums::STRONG_BYTES]
        end

        if checksums.blocks[candidate].strong == strong
          found = candidate.to_i64 * block_size
          break
        end
      end

      found
    end

    private def short_match(
      remainder : Bytes,
      checksums : Checksums,
      hasher : Digest::SHA256,
      sum : Bytes,
    ) : Int64?
      return if remainder.empty?
      return if checksums.short_final_size != remainder.size

      final = checksums.blocks.last
      return unless Checksums.weak(remainder) == final.weak

      hasher.reset
      hasher.update(remainder)
      hasher.final(sum)
      return unless sum[0, Checksums::STRONG_BYTES] == final.strong

      (checksums.blocks.size - 1).to_i64 * checksums.block_size
    end

    private def advance_checksum(
      rolled : UInt32,
      departing : UInt8,
      arriving : UInt8,
      length : Int32,
    ) : UInt32
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
