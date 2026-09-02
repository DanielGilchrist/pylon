require "../watch"
require "./unavailable"

module Pylon::Watch
  module Watcher
    extend self

    def open(root : String, ignores : Array(String), signals : Channel(Nil)) : Any | Unavailable
      {% if flag?(:linux) %}
        Inotify.open(root, ignores, signals)
      {% elsif flag?(:darwin) %}
        FSEvents.open(root, ignores, signals)
      {% end %}
    end
  end
end
