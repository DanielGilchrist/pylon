require "../../wire"

module Pylon::Wire
  module Delta
    struct OpsEncoder
      def initialize
        @ops = IO::Memory.new
        @pending_offset = 0_i64
        @pending_length = 0_i64
      end

      def copy_from_base(offset : Int64, length : Int64) : Nil
        if @pending_length > 0 && @pending_offset + @pending_length == offset
          @pending_length += length
          return
        end

        flush
        @pending_offset = offset
        @pending_length = length
      end

      def insert(piece : Bytes) : Nil
        return if piece.empty?

        flush
        @ops.write_byte(1_u8)
        @ops.write_bytes(piece.size.to_u32, FORMAT)
        @ops.write(piece)
      end

      def finished : Bytes
        flush
        @ops.to_slice
      end

      private def flush : Nil
        while @pending_length > 0
          length = Math.min(@pending_length, UInt32::MAX.to_i64)
          @ops.write_byte(0_u8)
          @ops.write_bytes(@pending_offset.to_u64, FORMAT)
          @ops.write_bytes(length.to_u32, FORMAT)
          @pending_offset += length
          @pending_length -= length
        end
      end
    end
  end
end
