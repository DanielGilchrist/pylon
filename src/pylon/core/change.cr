require "./entry"

module Pylon::Core
  struct Change
    def self.expand(changes : Array(Change)) : Array(Change)
      expanded = [] of Change
      changes.each { |change| widen(change.path, change.old, change.new, expanded) }
      expanded
    end

    private def self.widen(path : String, old : Entry?, new : Entry?, into : Array(Change)) : Nil
      if new.nil? || !new.kind.directory? || new.contents.empty?
        into << Change.new(path, old, new)
        return
      end

      into << Change.new(path, old, Entry.directory)

      new.contents.each do |name, child|
        widen(join(path, name), nil, child, into)
      end
    end

    private def self.join(path : String, name : String) : String
      path.empty? ? name : "#{path}/#{name}"
    end

    getter path : String
    getter old : Entry?
    getter new : Entry?

    def initialize(@path : String, @old : Entry?, @new : Entry?)
    end

    def ==(other : Change) : Bool
      path == other.path &&
        Entry.equal?(old, other.old, true) &&
        Entry.equal?(new, other.new, true)
    end
  end
end
