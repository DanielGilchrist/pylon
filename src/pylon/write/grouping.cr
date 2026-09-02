require "../core/changes"

module Pylon::Write
  struct Grouping
    def self.partition(changes : Core::Changes, & : Core::Change -> Bool) : Grouping
      grouping = new
      survivors = nil

      changes.each_with_index do |change, index|
        if yield change
          grouping.independent << index
        elsif change.new.nil?
          survivors ||= surviving_folded_paths(changes)

          if survivors.includes?(change.path.downcase)
            grouping.ordered << index
          else
            grouping.removals << index
          end
        else
          grouping.ordered << index
        end
      end

      grouping
    end

    private def self.surviving_folded_paths(changes : Core::Changes) : Set(String)
      folded = Set(String).new

      changes.each do |change|
        folded << change.path.downcase unless change.new.nil?
      end

      folded
    end

    getter independent = [] of Int32
    getter removals = [] of Int32
    getter ordered = [] of Int32
  end
end
