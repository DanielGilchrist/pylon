require "../core/changes"

module Pylon::Write
  struct Grouping
    def self.partition(changes : Core::Changes, & : Core::Change -> Bool) : Grouping
      grouping = new

      changes.each_with_index do |change, index|
        if yield change
          grouping.independent << index
        elsif change.new.nil?
          grouping.removals << index
        else
          grouping.ordered << index
        end
      end

      grouping
    end

    getter independent = [] of Int32
    getter removals = [] of Int32
    getter ordered = [] of Int32
  end
end
