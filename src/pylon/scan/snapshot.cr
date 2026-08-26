require "../core/entry"
require "./cache_entry"

module Pylon::Scan
  alias Cache = Hash(String, CacheEntry)

  struct Snapshot
    getter root : Core::Entry?
    getter cache : Cache

    def initialize(@root : Core::Entry?, @cache : Cache)
    end
  end
end
