require "./change"
require "./entry"

module Pylon::Core
  module Changes
    extend self

    def expand(changes : Array(Change)) : Array(Change)
      expanded = [] of Change
      changes.each { |change| widen(change.path, change.old, change.new, expanded) }
      expanded
    end

    private def widen(path : String, old : Entry?, new : Entry?, into : Array(Change)) : Nil
      if new.nil? || !new.kind.directory? || new.contents.empty?
        into << Change.new(path, old, new)
        return
      end

      into << Change.new(path, old, Entry.directory)

      new.contents.each do |name, child|
        widen(join(path, name), nil, child, into)
      end
    end

    private def join(path : String, name : String) : String
      path.empty? ? name : "#{path}/#{name}"
    end
  end
end
