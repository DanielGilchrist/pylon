require "../scan/scanner"
require "../disk"
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
      @disk = Disk.new(@root)
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
        @disk, @cache, now_ns, @ignores,
        baseline: @baseline,
        recheck: @recheck,
      ).scan

      @cache = snapshot.cache
      @by_digest = index(snapshot.cache)
      @baseline = @accelerated ? snapshot.root : nil
      @recheck = Set(String).new
      snapshot
    end

    def content_source(digests : Array(Bytes), budget : UInt64) : Wire::ContentSource
      wanted = within(digests, budget)

      Wire::ContentSource.new(
        emit: ->(io : IO) do
          buffer = Bytes.new(Wire::Chunks::CHUNK_BYTES)
          scratch = Wire::Chunks.scratch
          codec = Compress::Zstd.new

          wanted.each { |digest, path| @disk.stream(path, digest, io, buffer, codec, scratch) }
        end,
        count: wanted.size,
        materialise: -> { materialise(wanted) },
        digests: wanted.map(&.first).to_set,
      )
    end

    private def materialise(wanted : Array({Bytes, String})) : Wire::Contents
      contents = Wire::Contents.new(initial_capacity: wanted.size)

      wanted.each do |digest, path|
        content = @disk.read(path)
        contents[digest] = content if content
      end

      contents
    end

    private def within(digests : Array(Bytes), budget : UInt64) : Array({Bytes, String})
      wanted = [] of {Bytes, String}
      spent = 0_u64

      digests.each do |digest|
        path = @by_digest[digest]?
        next if path.nil?

        weight = @cache[path]?.try(&.metadata.size) || 0_u64
        break if !wanted.empty? && spent + weight > budget

        wanted << {digest, path}
        spent += weight
      end

      wanted
    end

    def contents(digests : Array(Bytes), budget : UInt64) : Wire::Contents
      contents = Wire::Contents.new
      spent = 0_u64

      digests.each do |digest|
        path = @by_digest[digest]?
        next if path.nil?

        weight = @cache[path]?.try(&.metadata.size) || 0_u64
        break if !contents.empty? && spent + weight > budget

        content = @disk.read(path)
        next if content.nil?

        contents[digest] = content
        spent += weight
      end

      contents
    end

    private def index(cache : Scan::Cache) : Hash(Bytes, String)
      by_digest = Hash(Bytes, String).new(initial_capacity: cache.size)
      cache.each { |path, entry| by_digest[entry.digest] = path }
      by_digest
    end

    def write(changes : Array(Core::Change), source : Wire::ContentSource) : Array(Write::Outcome)
      Write::Writer.new(@disk, Staging.new(source.contents), @cache).write(changes)
    end
  end
end
