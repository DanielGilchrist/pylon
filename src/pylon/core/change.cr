require "./entry"
require "./paths"

module Pylon::Core
  struct Change
    def self.expand(changes : Array(Change)) : Array(Change)
      expanded = [] of Change
      changes.each { |change| widen(change.path, change.old, change.new, expanded) }
      expanded
    end

    private def self.widen(path : String, old : Entry?, new : Entry?, into : Array(Change)) : Nil
      if !new.is_a?(Directory) || new.contents.empty?
        into << Change.new(path, old, new)
        return
      end

      into << Change.new(path, old, Directory.new)

      new.contents.each do |name, child|
        widen(Paths.join(path, name), nil, child, into)
      end
    end

    getter path : String
    getter old : Entry?
    getter new : Entry?

    def initialize(@path : String, @old : Entry?, @new : Entry?)
    end
  end
end
