require "../core/entry"
require "./cache"

module Pylon::Scan
  struct Snapshot
    getter root : Core::Entry?
    getter cache : Cache

    def initialize(@root : Core::Entry?, @cache : Cache) : Nil
    end
  end
end
