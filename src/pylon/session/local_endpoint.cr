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

    @baseline : Core::Entry?
    @recheck : Set(String)

    def initialize(@root : String, @ignores : Scan::Ignores = Scan::Ignores::NONE)
      @cache = Scan::Cache.new
      @by_digest = {} of Bytes => String
      @baseline = nil
      @recheck = Set(String).new
      @accelerated = false
      @filesystem = Scan::Disk.new(@root)
      @target = Write::DiskTarget.new(@root)
    end

    def accelerate! : Nil
      @accelerated = true
    end

    def mark_dirty(paths : Enumerable(String)) : Nil
      paths.each { |path| @recheck << path }
    end

    def invalidate : Nil
      @baseline = nil
      @recheck.clear
    end

    def scan(now_ns : Int64) : Scan::Snapshot
      snapshot = Scan::Scanner.new(
        @filesystem, @cache, now_ns, @ignores,
        baseline: @baseline,
        recheck: @recheck,
      ).scan

      @cache = snapshot.cache
      @by_digest = index(snapshot.cache)
      @baseline = @accelerated ? snapshot.root : nil
      @recheck = Set(String).new
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
