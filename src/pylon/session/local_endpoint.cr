require "digest/sha256"
require "../scan/scanner"
require "../watch/dirty"
require "../disk"
require "../write/writer"
require "../wire/message"
require "./staging"
require "./pending_write"

module Pylon::Session
  class LocalEndpoint
    private record Wanted, digest : Bytes, path : String, size : UInt64
    private record Located, path : String, size : UInt64

    getter root : String
    property cache : Scan::Cache
    property on_stream : Proc(UInt64, Nil)? = nil
    getter tally = Scan::Tally.new

    @baseline : Core::Entry?
    @recheck : Set(String)

    def initialize(@root : String, @ignores : Scan::Ignores = Scan::Ignores::NONE, @compression : Int32 = Compress::Zstd::DEFAULT_LEVEL)
      @cache = Scan::Cache.new
      @by_digest = {} of Bytes => Located
      @baseline = nil
      @recheck = Set(String).new
      @accelerated = false
      @disk = Disk.new(@root)
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
      @tally.reset

      snapshot = Scan::Scanner.new(
        @disk, @cache, now_ns, @ignores,
        baseline: @baseline,
        recheck: @recheck,
        tally: @tally,
      ).scan

      @tally.finish

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
        next unless content.is_a?(Bytes)

        contents[want.digest] = content if Digest::SHA256.digest(content).to_slice == want.digest
      end

      contents
    end

    private def within(digests : Array(Bytes), budget : UInt64) : Array(Wanted)
      wanted = [] of Wanted
      spent = 0_u64

      digests.each do |digest|
        located = @by_digest[digest]?
        next if located.nil?

        break if !wanted.empty? && spent + located.size > budget

        wanted << Wanted.new(digest, located.path, located.size)
        spent += located.size
      end

      wanted
    end

    def payload_size(changes : Array(Core::Change)) : UInt64?
      changes.sum(0_u64) do |change|
        entry = change.new
        next 0_u64 unless entry.is_a?(Core::File)

        cached = @cache[change.path]?
        return nil if cached.nil?

        cached.metadata.size
      end
    end

    private def index(cache : Scan::Cache) : Hash(Bytes, Located)
      by_digest = Hash(Bytes, Located).new(initial_capacity: cache.size)
      cache.each { |path, entry| by_digest[entry.digest] = Located.new(path, entry.metadata.size) }
      by_digest
    end

    def write(changes : Array(Core::Change), source : Wire::ContentSource) : Array(Write::Outcome)
      Write::Writer.new(@disk, Staging.new(source.contents), @cache).write(changes)
    end

    def write_begin(changes : Array(Core::Change), source : Wire::ContentSource) : PendingWrite
      outcomes = write(changes, source)
      PendingWrite.new(Proc(Array(Write::Outcome) | Fault).new { outcomes })
    end
  end
end
