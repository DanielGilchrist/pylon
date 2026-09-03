require "../core/entry"
require "./cache"

module Pylon::Scan
  struct Snapshot
    def initialize(@root : Core::Entry?, @cache : Cache) : Nil
    end

    getter root : Core::Entry?
    getter cache : Cache
  end
end
