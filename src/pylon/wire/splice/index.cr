module Pylon::Wire
  module Splice
    struct Index
      EMPTY          = -1
      SMALLEST_TABLE = 64

      def self.of(checksums : Checksums) : Index
        count = checksums.full_block_count
        size = SMALLEST_TABLE
        while size < count * 2
          size *= 2
        end
        table = Array(Int32).new(size, EMPTY)
        chain = Array(Int32).new(count, EMPTY)
        mask = (size - 1).to_u32

        count.times do |position|
          slot = slot_for(checksums.blocks[position].weak, mask)
          chain[position] = table[slot]
          table[slot] = position
        end

        new(checksums, table, chain, mask)
      end

      def self.slot_for(weak : UInt32, mask : UInt32) : Int32
        ((weak &+ (weak >> 16)) & mask).to_i32
      end

      private def initialize(
        @checksums : Checksums,
        @table : Array(Int32),
        @chain : Array(Int32),
        @mask : UInt32,
      ) : Nil
      end

      def each_candidate(weak : UInt32, & : Int32 ->) : Nil
        position = @table[Index.slot_for(weak, @mask)]

        while position != EMPTY
          yield position if @checksums.blocks[position].weak == weak
          position = @chain[position]
        end
      end
    end
  end
end
