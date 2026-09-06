require "../core/entry"
require "./cache"

module Pylon::Scan
  struct Snapshot
    def initialize(
      @root : Core::Entry?,
      @cache : Cache,
      @removed : Hash(String, CacheEntry),
      @updated : Array(String),
    ) : Nil
    end

    getter root : Core::Entry?
    getter cache : Cache
    getter removed : Hash(String, CacheEntry)
    getter updated : Array(String)

    def changed? : Bool
      !@removed.empty? || !@updated.empty?
    end
  end
end
