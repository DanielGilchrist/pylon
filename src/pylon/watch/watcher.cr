require "../brand"
require "../watch"
require "./unavailable"

module Pylon::Watch
  module Watcher
    extend self

    def open(root : String, ignores : Array(String), signals : Channel(Nil), brand : Brand) : Any | Unavailable
      {% if flag?(:linux) %}
        Inotify.open(root, ignores, signals, brand: brand)
      {% elsif flag?(:darwin) %}
        FSEvents.open(root, ignores, signals)
      {% end %}
    end
  end
end
