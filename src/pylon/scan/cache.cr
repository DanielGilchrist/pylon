module Pylon::Scan
  class Cache
    def initialize(initial_capacity : Int32 = 0) : Nil
      @entries = Hash(String, CacheEntry).new(initial_capacity: initial_capacity)
      @by_inode = Hash(UInt64, CacheEntry).new(initial_capacity: initial_capacity)
    end

    def size : Int32
      @entries.size
    end

    def [](path : String) : CacheEntry
      @entries[path]
    end

    def []?(path : String) : CacheEntry?
      @entries[path]?
    end

    def includes?(path : String) : Bool
      @entries.has_key?(path)
    end

    def paths : Array(String)
      @entries.keys
    end

    def each(& : String, CacheEntry ->) : Nil
      @entries.each { |path, entry| yield path, entry }
    end

    def store(path : String, entry : CacheEntry) : CacheEntry?
      previous = @entries[path]?
      @entries[path] = entry
      @by_inode[entry.metadata.inode] = entry
      previous
    end

    def forget(path : String) : CacheEntry?
      entry = @entries.delete(path)
      return if entry.nil?

      inode = entry.metadata.inode
      @by_inode.delete(inode) if @by_inode[inode]? == entry
      entry
    end

    def relocated(inode : UInt64) : CacheEntry?
      @by_inode[inode]?
    end
  end
end
