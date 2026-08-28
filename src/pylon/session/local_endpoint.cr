require "../scan/scanner"
require "../watch/dirty"
require "../disk"
require "../write/writer"
require "../wire/message"
require "./staging"

module Pylon::Session
  class LocalEndpoint
    private record Wanted, digest : Bytes, path : String, size : UInt64

    getter root : String
    property cache : Scan::Cache
    property on_stream : Proc(UInt64, Nil)? = nil

    @baseline : Core::Entry?
    @recheck : Set(String)

    def initialize(@root : String, @ignores : Scan::Ignores = Scan::Ignores::NONE, @compression : Int32 = Compress::Zstd::DEFAULT_LEVEL)
      @cache = Scan::Cache.new
      @by_digest = {} of Bytes => String
      @baseline = nil
      @recheck = Set(String).new
      @accelerated = false
      @disk = Disk.new(@root)
      @written = Deque(Array(Write::Outcome)).new
    end

    def accelerate! : Nil
      @accelerated = true
    end

    def invalidate : Nil
      @baseline = nil
      @recheck.clear
    end

    def mark_dirty(paths : Enumerable(String)) : Nil
      paths.each { |path| @recheck << path }
    end

    def mark_dirty(dirty : Watch::Dirty) : Nil
      case dirty
      in Watch::Everything
        invalidate
      in Watch::Touched
        mark_dirty(dirty.paths)
      end
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

      Wire::ContentSource::Streaming.new(
        digests: wanted.map(&.digest).to_set,
        emit: ->(io : IO) do
          buffer = Bytes.new(Wire::Chunks::CHUNK_BYTES)
          scratch = Wire::Chunks.scratch
          codec = Compress::Zstd.new(@compression)

          wanted.each do |want|
            @disk.stream(want.path, want.digest, io, buffer, codec, scratch)
            @on_stream.try(&.call(want.size))
          end
        end,
        materialise: -> { materialise(wanted) },
      )
    end

    private def materialise(wanted : Array(Wanted)) : Wire::Contents
      contents = Wire::Contents.new(initial_capacity: wanted.size)

      wanted.each do |want|
        content = @disk.read(want.path)
        contents[want.digest] = content if content
      end

      contents
    end

    private def within(digests : Array(Bytes), budget : UInt64) : Array(Wanted)
      wanted = [] of Wanted
      spent = 0_u64

      digests.each do |digest|
        path = @by_digest[digest]?
        next if path.nil?

        weight = @cache[path]?.try(&.metadata.size) || 0_u64
        break if !wanted.empty? && spent + weight > budget

        wanted << Wanted.new(digest, path, weight)
        spent += weight
      end

      wanted
    end

    def payload_size(changes : Array(Core::Change)) : UInt64?
      changes.sum(0_u64) do |change|
        entry = change.new

        if entry && entry.kind.file?
          @cache[change.path]?.try(&.metadata.size) || 0_u64
        else
          0_u64
        end
      end
    end

    private def index(cache : Scan::Cache) : Hash(Bytes, String)
      by_digest = Hash(Bytes, String).new(initial_capacity: cache.size)
      cache.each { |path, entry| by_digest[entry.digest] = path }
      by_digest
    end

    def write(changes : Array(Core::Change), source : Wire::ContentSource) : Array(Write::Outcome)
      Write::Writer.new(@disk, Staging.new(source.contents), @cache).write(changes)
    end

    def write_begin(changes : Array(Core::Change), source : Wire::ContentSource) : Nil
      @written.push(write(changes, source))
    end

    def write_await : Array(Write::Outcome)
      @written.shift? || [] of Write::Outcome
    end
  end
end
