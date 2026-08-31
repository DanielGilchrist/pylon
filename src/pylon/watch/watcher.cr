require "./unavailable"
require "./inotify"
require "./fsevents"

module Pylon::Watch
  {% if flag?(:linux) %}
    alias Any = Inotify
  {% elsif flag?(:darwin) %}
    alias Any = FSEvents
  {% else %}
    {% raise "pylon only supports watching on linux (inotify) and macos (fsevents)" %}
  {% end %}

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
