require "digest/sha256"
require "../scan/scanner"
require "../watch/dirty"
require "../disk"
require "../write/writer"
require "../wire/message"
require "./staging"
require "./pending_write"
require "./local_endpoint/settled_signatures"

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

    def initialize(@root : String, @ignores : Scan::Ignores = Scan::Ignores::NONE, @compression : Int32 = Compress::Zstd::DEFAULT_LEVEL) : Nil
      @cache = Scan::Cache.new
      @by_digest = Hash(Bytes, Located).new
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

    def register(dirty : Watch::Dirty) : Int32
      mark_dirty(dirty)

      case dirty
      in Watch::Everything
        Int32::MAX >> 2
      in Watch::Touched
        dirty.paths.size
      end
    end

    def scan(now_ns : Int64) : Core::Entry?
      @tally.reset

      snapshot = Scan::Scanner.new(
        @disk, @cache, now_ns, @ignores,
        baseline: @baseline,
        recheck: @recheck,
        tally: @tally,
      ).scan

      @tally.finish

      unless @cache.same?(snapshot.cache)
        @cache = snapshot.cache
        @by_digest = index(snapshot.cache)
      end
      @baseline = @accelerated ? snapshot.root : nil
      @recheck = Set(String).new
      snapshot.root
    end

    def delta_capable? : Bool
      false
    end

    def signatures_begin(pairs : Array(Wire::Message::SignaturesRequest::Pair)) : SettledSignatures
      SettledSignatures.new(signatures(pairs))
    end

    def signatures(pairs : Array(Wire::Message::SignaturesRequest::Pair)) : Wire::Delta::Signatures
      found = Wire::Delta::Signatures.new

      pairs.each do |pair|
        located = @by_digest[pair.base]?
        next if located.nil?
        next unless Wire::Delta.worthwhile?(located.size)

        content = verified_read(located.path, pair.base)
        next if content.nil?

        found[pair.wanted] = Wire::Delta::Based.new(pair.base, Wire::Delta.signature(content))
      end

      found
    end

    def content_source(digests : Array(Bytes), budget : UInt64, signatures : Wire::Delta::Signatures = Wire::Delta::Signatures.new) : Wire::ContentSource
      wanted = within(digests, budget)

      Wire::ContentSource::Streaming.new(
        digests: wanted.map(&.digest).to_set,
        emit: ->(io : IO) : Nil do
          buffer = Bytes.new(Wire::Chunks::CHUNK_BYTES)
          scratch = Wire::Chunks.scratch
          codec = Compress::Zstd.new(@compression)
          hasher = Digest::SHA256.new

          wanted.each do |want|
            patch = compute_patch(want, signatures)

            if patch
              emit_patch(io, want, patch, codec, scratch)
            else
              {% if flag?(:timing) %}
                Wire::Delta.fulls_sent += 1
                Wire::Delta.full_bytes += want.size
              {% end %}

              @disk.stream(want.path, want.digest, io, buffer, codec, scratch, hasher)
            end

            @on_stream.try(&.call(want.size))
          end
        end,
        materialise: -> : Wire::Contents { materialise(wanted) },
      )
    end

    private def compute_patch(want : Wanted, signatures : Wire::Delta::Signatures) : Wire::Patch?
      based = signatures[want.digest]?
      return if based.nil?
      return unless Wire::Delta.worthwhile?(want.size)

      content = verified_read(want.path, want.digest)
      return if content.nil?

      ops = Wire::Delta.compute(content, based.signature)
      return if ops.nil?

      Wire::Patch.new(based.base, ops)
    end

    private def emit_patch(io : IO, want : Wanted, patch : Wire::Patch, codec : Compress::Codec, scratch : Bytes) : Nil
      {% if flag?(:timing) %}
        Wire::Delta.deltas_sent += 1
        Wire::Delta.delta_bytes += patch.ops.size
      {% end %}

      Wire::Binary.write_bytes(io, want.digest)
      Wire::ContentKind::Patch.write(io)
      Wire::Binary.write_bytes(io, patch.base)
      Wire::Chunks.write_all(io, patch.ops, codec, scratch)
    end

    private def materialise(wanted : Array(Wanted)) : Wire::Contents
      contents = Wire::Contents.new(initial_capacity: wanted.size)
      hasher = Digest::SHA256.new
      sum = Bytes.new(Wire::DIGEST_BYTES)

      wanted.each do |want|
        content = @disk.read(want.path)
        next unless content.is_a?(Bytes)

        hasher.reset
        hasher.update(content)
        hasher.final(sum)

        contents[want.digest] = content if sum == want.digest
      end

      contents
    end

    private def within(digests : Array(Bytes), budget : UInt64) : Array(Wanted)
      wanted = Array(Wanted).new
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

    def known_size(path : String) : UInt64?
      @cache[path]?.try(&.metadata.size)
    end

    def payload_size(changes : Core::Changes) : UInt64?
      changes.sum(0_u64) do |change|
        entry = change.new
        next 0_u64 unless entry.is_a?(Core::File)

        cached = @cache[change.path]?
        return if cached.nil?

        cached.metadata.size
      end
    end

    private def index(cache : Scan::Cache) : Hash(Bytes, Located)
      by_digest = Hash(Bytes, Located).new(initial_capacity: cache.size)
      cache.each { |path, entry| by_digest[entry.digest] = Located.new(path, entry.metadata.size) }
      by_digest
    end

    def write(changes : Core::Changes, source : Wire::ContentSource, relocations : Array(Core::Relocation) = Array(Core::Relocation).new) : Array(Write::Outcome)
      Write::Writer.new(@disk, Staging.new(source.contents, self), @cache, Time.utc.to_unix_ns.to_i64, @ignores).write(changes, relocations)
    end

    def recovered_content(digest : Bytes) : Bytes?
      located = @by_digest[digest]?
      return if located.nil?

      verified_read(located.path, digest)
    end

    private def verified_read(path : String, digest : Bytes) : Bytes?
      case (content = @disk.read(path))
      in Problem
        nil
      in Bytes
        Core::Digests.matches?(content, digest) ? content : nil
      end
    end

    def write_begin(changes : Core::Changes, source : Wire::ContentSource, relocations : Array(Core::Relocation)) : PendingWrite
      outcomes = write(changes, source, relocations)
      PendingWrite.new(Proc(Array(Write::Outcome) | Fault).new { outcomes })
    end
  end
end
