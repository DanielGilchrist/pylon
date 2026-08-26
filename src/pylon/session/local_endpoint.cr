require "../scan/scanner"
require "../scan/disk"
require "../write/disk_target"
require "../write/writer"
require "../wire/message"
require "./staging"

module Pylon::Session
  class LocalEndpoint
    getter root : String
    property cache : Scan::Cache

    def initialize(@root : String, @ignores : Scan::Ignores = Scan::Ignores::NONE)
      @cache = Scan::Cache.new
      @by_digest = {} of Bytes => String
      @filesystem = Scan::Disk.new(@root)
      @target = Write::DiskTarget.new(@root)
    end

    def scan(now_ns : Int64) : Scan::Snapshot
      snapshot = Scan::Scanner.new(@filesystem, @cache, now_ns, @ignores).scan
      @cache = snapshot.cache
      @by_digest = index(snapshot.cache)
      snapshot
    end

    def contents(digests : Array(Bytes)) : Wire::Contents
      contents = Wire::Contents.new(initial_capacity: digests.size)

      digests.each do |digest|
        path = @by_digest[digest]?
        next if path.nil?

        content = @filesystem.read(path)
        contents[digest] = content if content
      end

      contents
    end

    private def index(cache : Scan::Cache) : Hash(Bytes, String)
      by_digest = Hash(Bytes, String).new(initial_capacity: cache.size)
      cache.each { |path, entry| by_digest[entry.digest] = path }
      by_digest
    end

    def write(changes : Array(Core::Change), contents : Wire::Contents) : Array(Write::Outcome)
      Write::Writer.new(@target, Staging.new(contents), @cache).apply(changes)
    end
  end
end
