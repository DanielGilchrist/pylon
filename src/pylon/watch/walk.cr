require "../filesystem"

module Pylon::Watch
  # Both watchers walk freshly created (or, at startup, existing) directory trees, and a
  # directory can vanish or turn unreadable mid-walk. Here we effectively wrap that walk once
  # so every walk shares the same handling of `Filesystem.each_child`'s failure values: a
  # vanished directory needs nothing (its deletion arrives as its own event), while children
  # we could not enumerate would otherwise change without being noticed, so the watcher
  # conservatively marks itself fresh and the next drain reports everything dirty for a full
  # rescan to observe. Includers provide @lock and @fresh.
  module Walk
    private def walk(absolute_path : String, & : String ->) : Nil
      listed = Filesystem.each_child(absolute_path) { |name| yield name }

      case listed
      in Nil, Missing
      in Problem
        @lock.synchronize { @fresh = true }
      end
    end
  end
end
