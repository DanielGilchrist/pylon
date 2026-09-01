require "./change"
require "./entry"

module Pylon::Core
  module Digests
    extend self

    class Collector
      def initialize
        @wanted = [] of Bytes
        @seen = Set(Bytes).new
      end

      def required(changes : Array(Change), offset : Int32 = 0) : Array(Bytes)
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

    def required(changes : Array(Change)) : Array(Bytes)
      Collector.new.required(changes)
    end
  end
end
