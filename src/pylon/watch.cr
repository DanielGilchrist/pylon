require "./watch/inotify"
require "./watch/fsevents"

module Pylon::Watch
  {% if flag?(:linux) %}
    alias Any = Inotify
  {% elsif flag?(:darwin) %}
    alias Any = FSEvents
  {% else %}
    {% raise "pylon only supports watching on linux (inotify) and macos (fsevents)" %}
  {% end %}
end
