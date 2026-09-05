require "../brand"
require "../platform"
require "../watch"
require "./unavailable"

module Pylon::Watch
  module Watcher
    extend self

    def open(
      root : String,
      ignores : Array(String),
      signals : Channel(Nil),
      brand : Brand,
    ) : Any | Unavailable
      Platform.select do
        macos { FSEvents.open(root, ignores, signals) }
        linux { Inotify.open(root, ignores, signals, brand: brand) }
      end
    end
  end
end
