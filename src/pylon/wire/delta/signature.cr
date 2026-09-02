require "./block"

module Pylon::Wire
  module Delta
    record Signature, block_size : Int32, base_size : Int64, blocks : Array(Block) do
      def full_block_count : Int32
        (base_size // block_size).to_i32
      end

      def short_final_size : Int32
        (base_size % block_size).to_i32
      end
    end
  end
end
