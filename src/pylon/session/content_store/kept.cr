module Pylon::Session
  class ContentStore
    # The digests the store has a snapshot of, in the order it took them. Whether a digest is held
    # and how old it is are one concern, not two: a digest that leaves the membership has to leave
    # the order with it, or a later prune offers up a copy that is no longer on disk.
    #
    # Not synchronised. The store owns the lock.
    class Kept
      def initialize : Nil
        @digests = Set(Bytes).new
        @order = Deque(Bytes).new
      end

      def includes?(digest : Bytes) : Bool
        @digests.includes?(digest)
      end

      def add(digest : Bytes) : Nil
        @order.push(digest) if @digests.add?(digest)
      end

      # Forgets all of `digests` in one pass. Removing them one at a time walks the order once
      # each, which costs real time when a prune drops thousands at once.
      def delete_all(digests : Array(Bytes)) : Nil
        return if digests.empty?

        removing = digests.to_set
        removing.each { |digest| @digests.delete(digest) }

        remaining = Deque(Bytes).new(@digests.size)
        @order.each { |digest| remaining.push(digest) unless removing.includes?(digest) }
        @order = remaining
      end

      # The oldest digests the tree no longer points at, enough of them to come back to the bound.
      def surplus(live : Locations, *, bound : Int32) : Array(Bytes)
        orphaned = @order.reject { |digest| live.has?(digest) }

        orphaned.first(Math.max(orphaned.size - bound, 0))
      end
    end
  end
end
