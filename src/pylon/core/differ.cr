require "./change"
require "./entry"

module Pylon::Core
  module Differ
    extend self

    def diff(base : Entry?, target : Entry?) : Array(Change)
      changes = [] of Change
      walk("", base, target, changes)
      changes
    end

    private def walk(path : String, base : Entry?, target : Entry?, into : Array(Change)) : Nil
      return if Entry.equal?(base, target, true)

      unless base && target && base.kind.directory? && target.kind.directory?
        into << Change.new(path, base, target)
        return
      end

      base.contents.each do |name, child|
        walk(join(path, name), child, target.contents[name]?, into)
      end

      target.contents.each do |name, child|
        next if base.contents.has_key?(name)

        walk(join(path, name), nil, child, into)
      end
    end

    private def join(path : String, name : String) : String
      path.empty? ? name : "#{path}/#{name}"
    end
  end
end
