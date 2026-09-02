require "../change"
require "../changes"
require "../entry"

module Pylon::Core
  module Digests
    struct Collector
      def initialize : Nil
        @wanted = Array(Bytes).new
        @seen = Set(Bytes).new
      end

      def required(changes : Changes, offset : Int32 = 0) : Array(Bytes)
        @wanted.clear
        @seen.clear

        changes.each(within: offset...) { |change| collect(change.new) }

        @wanted
      end

      private def collect(entry : Entry?) : Nil
        case entry
        in Nil, SymbolicLink, Untracked, Problematic
          nil
        in File
          @wanted << entry.digest if @seen.add?(entry.digest)
        in Directory
          entry.contents.each_value { |child| collect(child) }
        end
      end
    end
  end
end
