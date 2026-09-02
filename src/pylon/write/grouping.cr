require "../core/changes"

module Pylon::Write
  struct Grouping
    def self.partition(changes : Core::Changes, & : Core::Change -> Bool) : Grouping
      grouping = new
      colliding = changes.case_colliding_delete_indexes

      changes.each_with_index do |change, index|
        if yield change
          grouping.independent << index
        elsif change.new.nil? && !colliding.includes?(index)
          grouping.removals << index
        else
          grouping.ordered << index
        end
      end

      grouping
    end

    getter independent = Array(Int32).new
    getter removals = Array(Int32).new
    getter ordered = Array(Int32).new
  end
end
