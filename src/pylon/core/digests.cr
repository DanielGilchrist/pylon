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
      return if entry.nil?

      if entry.kind.file?
        digest = entry.digest
        wanted << digest if digest && seen.add?(digest)
        return
      end

      entry.contents.each_value { |child| collect(child, wanted, seen) }
    end
  end
end
