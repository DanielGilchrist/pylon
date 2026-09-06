module Pylon::Watch
  Platform.select do
    macos { alias Any = FSEvents }
    linux { alias Any = Inotify }
  end
end
