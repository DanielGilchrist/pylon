require "./change"
require "./changes"
require "./entry"

module Pylon::Core
  module Applier
    extend self

    private class Pending
      getter value : Entry?
      getter? assigned = false
      getter children : Hash(String, Pending)? = nil

      def child(name : String) : Pending
        children = (@children ||= Hash(String, Pending).new)
        children[name] ||= Pending.new
      end

      def assign(entry : Entry?) : Nil
        @value = entry
        @assigned = true
        @children.try(&.clear)
      end
    end

    def apply(base : Entry?, changes : Changes) : Entry?
      return base if changes.empty?

      root = Pending.new

      changes.each do |change|
        node = root

        unless change.path.empty?
          change.path.split('/') do |name|
            node = node.child(name)
          end
        end

        node.assign(change.new)
      end

      merge(base, root)
    end

    private def merge(base : Entry?, node : Pending) : Entry?
      current = node.assigned? ? node.value : base

      children = node.children
      return current if children.nil? || children.empty?

      directory = current.is_a?(Directory) ? current : Directory.new
      contents = directory.contents.dup

      children.each do |name, child|
        merged = merge(contents[name]?, child)

        if merged.nil?
          contents.delete(name)
        else
          contents[name] = merged
        end
      end

      return current if contents.empty? && !current.is_a?(Directory)

      Directory.new(contents)
    end
  end
end
