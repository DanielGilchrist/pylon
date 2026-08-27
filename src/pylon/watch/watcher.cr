require "./inotify"
require "./watchman/subscriber"

module Pylon::Watch
  {% if flag?(:linux) %}
    alias Any = Inotify
  {% else %}
    alias Any = Watchman::Subscriber
  {% end %}

  module Watcher
    extend self

    # Linux watches inotify directly, so the dev box needs nothing installed.
    # macOS goes through watchman, which owns FSEvents for us.
    def open(root : String, ignores : Array(String), signals : Channel(Nil), name : String = "pylon") : Any?
      {% if flag?(:linux) %}
        Inotify.open(root, ignores, signals)
      {% else %}
        Watchman::Subscriber.open(root, ignores, signals, name)
      {% end %}
    end
  end
end
