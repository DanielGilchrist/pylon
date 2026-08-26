require "./change"
require "./entry"

module Pylon::Core
  module Applier
    extend self

    private class Pending
      property value : Entry?
      property? assigned = false
      getter children = {} of String => Pending
    end

    def apply(base : Entry?, changes : Array(Change)) : Entry?
      return base if changes.empty?

      root = Pending.new

      changes.each do |change|
        node = root

        segments(change.path).each do |name|
          node = node.children[name] ||= Pending.new
        end

        node.value = change.new
        node.assigned = true
        node.children.clear
      end

      merge(base, root)
    end

    private def merge(base : Entry?, node : Pending) : Entry?
      current = node.assigned? ? node.value : base
      return current if node.children.empty?

      directory = current && current.kind.directory? ? current : Entry.directory
      contents = directory.contents.dup

      node.children.each do |name, child|
        merged = merge(contents[name]?, child)

        if merged.nil?
          contents.delete(name)
        else
          contents[name] = merged
        end
      end

      directory.with_contents(contents)
    end

    private def segments(path : String) : Array(String)
      path.empty? ? [] of String : path.split('/')
    end
  end
end
