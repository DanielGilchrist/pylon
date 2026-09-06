require "sync"

module Pylon::Watch
  class DirtyPaths
    def initialize(@signals : Channel(Nil)) : Nil
      @paths = Set(String).new
      @lock = Sync::Mutex.new
      @fresh = false
    end

    getter signals : Channel(Nil)

    def add(path : String) : Nil
      @lock.synchronize { @paths << path }
    end

    def all_dirty! : Nil
      @lock.synchronize { @fresh = true }
    end

    def add_tree(root : String, relative : String, ignores : Scan::Ignores) : Nil
      each_child(File.join(root, relative)) do |name|
        child = Core::Paths.join(relative, name)
        next if ignores.ignore?(child)

        add(child)
        add_tree(root, child, ignores) if Dir.exists?(File.join(root, child))
      end
    end

    def each_child(absolute : String, & : String ->) : Nil
      listed = Filesystem.each_child(absolute) { |name| yield name }

      case listed
      in Nil, Missing
      in Problem
        all_dirty!
      end
    end

    def consume : Dirty
      @lock.synchronize do
        dirty = @fresh ? Everything.new : Touched.new(@paths.to_a)
        @paths.clear
        @fresh = false
        dirty
      end
    end

    def signal : Nil
      select
      when @signals.send(nil)
      else
      end
    end
  end
end
