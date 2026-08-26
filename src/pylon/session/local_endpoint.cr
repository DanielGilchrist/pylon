require "../scan/scanner"
require "../scan/disk"
require "../write/disk_target"
require "../write/writer"

module Pylon::Session
  class LocalEndpoint
    getter root : String
    getter cache : Scan::Cache

    def initialize(@root : String, @ignores : Scan::Ignores = Scan::Ignores::NONE)
      @cache = Scan::Cache.new
      @by_digest = {} of Bytes => String
      @filesystem = Scan::PosixFilesystem.new(@root)
      @target = Write::PosixTarget.new(@root)
    end

    def scan(now_ns : Int64) : Scan::Snapshot
      snapshot = Scan::Scanner.new(@filesystem, @cache, now_ns, @ignores).scan
      @cache = snapshot.cache
      @by_digest = index(snapshot.cache)
      snapshot
    end

    def content(digest : Bytes) : Bytes?
      path = @by_digest[digest]?
      return nil if path.nil?

      @filesystem.read(path)
    end

    private def index(cache : Scan::Cache) : Hash(Bytes, String)
      by_digest = Hash(Bytes, String).new(initial_capacity: cache.size)
      cache.each { |path, entry| by_digest[entry.digest] = path }
      by_digest
    end

    def write(changes : Array(Core::Change), staging) : Array(Write::Outcome)
      Write::Writer.new(@target, staging, @cache).apply(changes)
    end
  end
end
