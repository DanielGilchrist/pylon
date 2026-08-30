require "./change"
require "./entry"

module Pylon::Core
  module Digests
    extend self

    def required(changes : Array(Change)) : Array(Bytes)
      wanted = [] of Bytes
      seen = Set(Bytes).new

      changes.each { |change| collect(change.new, wanted, seen) }

      wanted
    end

    private def collect(entry : Entry?, wanted : Array(Bytes), seen : Set(Bytes)) : Nil
      case entry
      in Nil, SymbolicLink, Untracked, Problematic
        nil
      in File
        wanted << entry.digest if seen.add?(entry.digest)
      in Directory
        entry.contents.each_value { |child| collect(child, wanted, seen) }
      end
    end
  end
end
