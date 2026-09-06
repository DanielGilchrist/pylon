module Pylon::Watch
  module Watcher
    extend self

    def open(
      root : String,
      ignores : Array(String),
      dirty_paths : DirtyPaths,
      brand : Brand,
    ) : Any | Problem
      Platform.select do
        macos { FSEvents.open(root, ignores, dirty_paths) }
        linux { Inotify.open(root, ignores, dirty_paths, brand: brand) }
      end
    end
  end
end
