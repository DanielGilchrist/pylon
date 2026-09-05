require "../core/changes"

module Pylon::Write
  struct Grouping
    def self.partition(changes : Core::Changes, & : Core::Change -> Bool) : Grouping
      grouping = new
      colliding = changes.case_colliding_delete_indexes

      changes.each_with_index do |change, index|
        if yield change
          grouping.parallel << index
        elsif change.new.nil? && !colliding.includes?(index)
          grouping.deletions << index
        else
          grouping.sequential << index
        end
      end

      grouping
    end

    getter parallel = Array(Int32).new
    getter deletions = Array(Int32).new
    getter sequential = Array(Int32).new
  end
end
