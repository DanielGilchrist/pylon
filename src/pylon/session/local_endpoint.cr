require "digest/sha256"
require "../compress/identity"
require "../compress/prefix"
require "../core/applier"
require "../core/digests"
require "../scan/scanner"
require "../wire/prefixed"
require "../watch/dirty"
require "../disk"
require "../write/writer"
require "../wire/message"
require "./staging"
require "./content_store"
require "../discard"
require "./settled"

module Pylon::Session
  class LocalEndpoint
    @baseline : Core::Entry?
    @recheck : Set(String)

    def initialize(@root : String, @ignores : Scan::Ignores, @compression : Int32) : Nil
      @cache = Scan::Cache.new
      @by_digest = Hash(Bytes, Located).new
      @baseline = nil
      @recheck = Set(String).new
      @accelerated = false
      @disk = Disk.new(@root)
    end

    getter root : String
    property cache : Scan::Cache
    property on_stream : Proc(UInt64, Nil)? = nil
    property store : ContentStore? = nil
    getter tally = Scan::Tally.new

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
        keeper: @store || Discard.new,
      ).scan

      @tally.finish

      unless @cache.same?(snapshot.cache)
        @cache = snapshot.cache
        @by_digest = index(snapshot.cache)
        @store.try(&.prune { |digest| @by_digest.has_key?(digest) })
      end
      @baseline = snapshot.root if @accelerated
      @recheck = Set(String).new
      snapshot.root
    end

    def delta_capable? : Bool
      false
    end

    def signatures_begin(
      pairs : Array(Wire::Message::SignaturesRequest::Pair),
    ) : Settled(Wire::Delta::Signatures)
      Settled.new(signatures(pairs))
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

    def retained?(digest : Bytes) : Bool
      store = @store
      return false if store.nil?

      store.holds?(digest)
    end

    def availability_begin(digests : Array(Bytes)) : Settled(Array(Bytes))
      Settled.new(available(digests))
    end

    def available(digests : Array(Bytes)) : Array(Bytes)
      store = @store
      indexed = digests.select { |digest| @by_digest.has_key?(digest) }
      return indexed if store.nil?

      indexed.concat(store.available(digests.reject { |digest| @by_digest.has_key?(digest) }))
    end

    def content_begin(
      digests : Array(Bytes),
      budget : UInt64,
      signatures : Wire::Delta::Signatures,
      bases : Wire::Prefixed::Bases,
    ) : Settled(Wire::ContentSource)
      Settled(Wire::ContentSource).new(content_source(digests, budget, signatures, bases))
    end

    def content_source(
      digests : Array(Bytes),
      budget : UInt64,
      signatures : Wire::Delta::Signatures,
      bases : Wire::Prefixed::Bases,
    ) : Wire::ContentSource
      wanted = within(digests, budget)

      Wire::ContentSource::Streaming.new(
        digests: wanted.map(&.digest).to_set,
        emit: ->(io : IO) : Nil do
          buffer = Bytes.new(Wire::Chunks::CHUNK_BYTES)
          scratch = Wire::Chunks.scratch
          codec = Compress::Zstd.new(@compression)
          hasher = Digest::SHA256.new
          prefix = Compress::Prefix.new

          wanted.each do |want|
            case (delivery = plan_delivery(want, bases, signatures, prefix))
            in Wire::Prefixed
              emit_prefixed(io, want, delivery, scratch)
            in Wire::Patch
              emit_patch(io, want, delivery, codec, scratch)
            in Nil
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

    def write(
      changes : Core::Changes,
      source : Wire::ContentSource,
      relocations : Array(Core::Relocation) = Array(Core::Relocation).new,
    ) : Array(Write::Outcome)
      staging = Staging.new(source.contents, self)
      writer = Write::Writer.new(@disk, staging, @cache, Time.utc.to_unix_ns.to_i64, @ignores)
      writer.write(changes, relocations)
    end

    def recovered_content(digest : Bytes) : Bytes?
      located = @by_digest[digest]?
      return stored_content(digest) if located.nil?

      verified_read(located.path, digest) || stored_content(digest)
    end

    def base_content(digest : Bytes, path : String) : Bytes?
      verified_read(path, digest) || recovered_content(digest)
    end

    def write_begin(
      changes : Core::Changes,
      source : Wire::ContentSource,
      relocations : Array(Core::Relocation),
    ) : Settled(Array(Write::Outcome))
      Settled.new(write(changes, source, relocations))
    end

    private def stored_content(digest : Bytes) : Bytes?
      store = @store
      return if store.nil?

      store.content(digest)
    end

    private def plan_delivery(
      want : Wanted,
      bases : Wire::Prefixed::Bases,
      signatures : Wire::Delta::Signatures,
      prefix : Compress::Prefix,
    ) : Wire::Prefixed | Wire::Patch | Nil
      compute_prefixed(want, bases, prefix) || compute_patch(want, signatures)
    end

    private def compute_prefixed(
      want : Wanted,
      bases : Wire::Prefixed::Bases,
      prefix : Compress::Prefix,
    ) : Wire::Prefixed?
      store = @store
      return if store.nil?
      return unless Wire::Prefixed.worthwhile?(want.size)

      base_digest = bases[want.digest]?
      return if base_digest.nil?

      base = store.content(base_digest)
      return if base.nil?

      content = verified_read(want.path, want.digest)
      return if content.nil?

      frame = prefix.compress(content, base, Bytes.new(Compress::Zstd.bound(content.size)))
      return if frame.is_a?(Compress::Error)

      Wire::Prefixed.new(base_digest, frame)
    end

    private def emit_prefixed(
      io : IO,
      want : Wanted,
      prefixed : Wire::Prefixed,
      scratch : Bytes,
    ) : Nil
      {% if flag?(:timing) %}
        Wire::Delta.prefixed_sent += 1
        Wire::Delta.prefixed_bytes += prefixed.frame.size
      {% end %}

      Wire::Binary.write_bytes(io, want.digest)
      Wire::ContentKind::Prefixed.write(io)
      Wire::Binary.write_bytes(io, prefixed.base)
      Wire::Chunks.write_all(io, prefixed.frame, Compress::Identity.new, scratch)
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

    private def emit_patch(
      io : IO,
      want : Wanted,
      patch : Wire::Patch,
      codec : Compress::Codec,
      scratch : Bytes,
    ) : Nil
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

    private def index(cache : Scan::Cache) : Hash(Bytes, Located)
      by_digest = Hash(Bytes, Located).new(initial_capacity: cache.size)
      cache.each { |path, entry| by_digest[entry.digest] = Located.new(path, entry.metadata.size) }
      by_digest
    end

    private def verified_read(path : String, digest : Bytes) : Bytes?
      case (content = @disk.read(path))
      in Problem
        nil
      in Bytes
        content if Core::Digests.matches?(content, digest)
      end
    end

    private record Wanted, digest : Bytes, path : String, size : UInt64
    private record Located, path : String, size : UInt64
  end
end
