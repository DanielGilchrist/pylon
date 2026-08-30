require "./change"
require "./entry"
require "./paths"

module Pylon::Core
  module Differ
    extend self

    def diff(base : Entry?, target : Entry?) : Array(Change)
      changes = [] of Change
      walk("", base, target, changes)
      changes
    end

    private def walk(path : String, base : Entry?, target : Entry?, into : Array(Change)) : Nil
      return if base == target

      unless base.is_a?(Directory) && target.is_a?(Directory)
        into << Change.new(path, base, target)
        return
      end

      base.contents.each do |name, child|
        walk(Paths.join(path, name), child, target.contents[name]?, into)
      end

      target.contents.each do |name, child|
        next if base.contents.has_key?(name)

        walk(Paths.join(path, name), nil, child, into)
      end
    end
  end
end
