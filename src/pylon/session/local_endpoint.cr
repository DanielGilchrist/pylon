require "digest/sha256"

module Pylon::Session
  class LocalEndpoint
    record Wanted, digest : Bytes, path : String, size : UInt64

    @previous_tree : Core::Entry?
    @recheck : Set(String)

    def initialize(@root : String, @ignores : Scan::Ignores, @compression : Int32) : Nil
      @cache = Scan::Cache.new
      @locations = Locations.new
      @previous_tree = nil
      @recheck = Set(String).new
      @watched = false
      @disk = Disk.new(@root)
    end

    getter root : String
    property cache : Scan::Cache
    getter sent = Progress.new
    property kept : ContentStore? = nil
    getter scanned = Progress.new

    def invalidate : Nil
      @previous_tree = nil
      @recheck.clear
    end

    def mark_dirty(dirty : Watch::Dirty) : Int32
      @watched = true

      case dirty
      in Watch::Everything
        invalidate
        Int32::MAX >> 2
      in Watch::Touched
        dirty.paths.each { |path| @recheck << path }
        dirty.paths.size
      end
    end

    def scan(now_ns : Int64) : Core::Entry?
      @scanned.reset

      snapshot = Scan::Scanner.new(
        @disk, @cache, now_ns, @ignores,
        previous_tree: @previous_tree,
        recheck: @recheck,
        scanned: @scanned,
        keeper: @kept || Discard.new,
      ).scan

      @scanned.finish

      @cache = snapshot.cache
      snapshot.removed.each { |path, entry| @locations.forget(entry.digest, path) }
      snapshot.updated.each do |path|
        entry = @cache[path]
        @locations.remember(entry.digest, path, entry.metadata.size)
      end
      prune_kept if snapshot.changed?
      @previous_tree = snapshot.root if @watched
      @recheck = Set(String).new
      snapshot.root
    end

    def remote? : Bool
      false
    end

    def request_checksums(bases : Wire::Bases) : Settled(Wire::Checksums::Map)
      Settled.new(checksums(bases))
    end

    def checksums(bases : Wire::Bases) : Wire::Checksums::Map
      found = Wire::Checksums::Map.new

      bases.each do |wanted, base|
        located = @locations.locate(base)
        next if located.nil?
        next unless Wire::Splice.worthwhile?(located.size)

        content = verified_read(located.path, base)
        next if content.nil?

        found[wanted] = Wire::Checksums.of(base, content)
      end

      found
    end

    def holds?(digest : Bytes) : Bool
      kept = @kept
      return false if kept.nil?

      kept.holds?(digest)
    end

    def request_reusable(digests : Array(Bytes)) : Settled(Array(Bytes))
      Settled.new(reusable(digests))
    end

    def reusable(digests : Array(Bytes)) : Array(Bytes)
      kept = @kept
      indexed = digests.select { |digest| @locations.has?(digest) }
      return indexed if kept.nil?

      indexed.concat(kept.held(digests.reject { |digest| @locations.has?(digest) }))
    end

    def request_content(
      digests : Array(Bytes),
      budget : UInt64,
      checksums : Wire::Checksums::Map,
      bases : Wire::Bases,
    ) : Settled(Wire::ContentSource)
      Settled(Wire::ContentSource).new(content_source(digests, budget, checksums, bases))
    end

    def content_source(
      digests : Array(Bytes),
      budget : UInt64,
      checksums : Wire::Checksums::Map,
      bases : Wire::Bases,
    ) : Wire::ContentSource
      Delivery.new(self, within(digests, budget), checksums, bases)
    end

    def size_of(path : String) : UInt64?
      @cache[path]?.try(&.metadata.size)
    end

    def total_size(changes : Core::Changes) : UInt64?
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

    def content(digest : Bytes) : Bytes?
      located = @locations.locate(digest)
      return kept_content(digest) if located.nil?

      verified_read(located.path, digest) || kept_content(digest)
    end

    def content(digest : Bytes, *, prefer : String) : Bytes?
      verified_read(prefer, digest) || content(digest)
    end

    def request_write(
      changes : Core::Changes,
      source : Wire::ContentSource,
      relocations : Array(Core::Relocation),
    ) : Settled(Array(Write::Outcome))
      Settled.new(write(changes, source, relocations))
    end

    protected def emit(
      io : IO,
      wanted : Array(Wanted),
      checksums : Wire::Checksums::Map,
      bases : Wire::Bases,
    ) : Nil
      buffer = Bytes.new(Wire::Chunks::CHUNK_BYTES)
      scratch = Wire::Chunks.scratch
      codec = Compress::Zstd.new(@compression)
      hasher = Digest::SHA256.new
      dictionary = Compress::Dictionary.new

      wanted.each do |want|
        case (delivery = plan_delivery(want, bases, checksums, dictionary))
        in Wire::Dictionary
          emit_dictionary(io, want, delivery, scratch)
        in Wire::Spliced
          emit_spliced(io, want, delivery, codec, scratch)
        in Nil
          {% if flag?(:timing) %}
            Wire::Splice.fulls_sent += 1
            Wire::Splice.full_bytes += want.size
          {% end %}

          @disk.stream(want.path, want.digest, io, buffer, codec, scratch, hasher)
        end

        @sent.add_file
        @sent.add_bytes(want.size.to_i64)
      end
    end

    protected def materialise(wanted : Array(Wanted)) : Wire::Contents
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

    private def kept_content(digest : Bytes) : Bytes?
      kept = @kept
      return if kept.nil?

      kept.content(digest)
    end

    private def plan_delivery(
      want : Wanted,
      bases : Wire::Bases,
      checksums : Wire::Checksums::Map,
      dictionary : Compress::Dictionary,
    ) : Wire::Dictionary | Wire::Spliced | Nil
      plan_dictionary(want, bases, dictionary) || plan_splice(want, checksums)
    end

    private def plan_dictionary(
      want : Wanted,
      bases : Wire::Bases,
      dictionary : Compress::Dictionary,
    ) : Wire::Dictionary?
      kept = @kept
      return if kept.nil?
      return unless Wire::Dictionary.worthwhile?(want.size)

      base_digest = bases[want.digest]?
      return if base_digest.nil?

      base = kept.content(base_digest)
      return if base.nil?

      content = verified_read(want.path, want.digest)
      return if content.nil?

      frame = dictionary.compress(content, base, Bytes.new(Compress::Zstd.bound(content.size)))
      return if frame.is_a?(Problem)

      Wire::Dictionary.new(base_digest, frame)
    end

    private def emit_dictionary(
      io : IO,
      want : Wanted,
      dictionary : Wire::Dictionary,
      scratch : Bytes,
    ) : Nil
      {% if flag?(:timing) %}
        Wire::Splice.dictionaries_sent += 1
        Wire::Splice.dictionary_bytes += dictionary.frame.size
      {% end %}

      Wire::Binary.write_digest(io, want.digest)
      Wire::ContentKind::Dictionary.write(io)
      Wire::Binary.write_digest(io, dictionary.base)
      Wire::Chunks.write_all(io, dictionary.frame, Compress::Identity.new, scratch)
    end

    private def plan_splice(want : Wanted, checksums : Wire::Checksums::Map) : Wire::Spliced?
      base_checksums = checksums[want.digest]?
      return if base_checksums.nil?
      return unless Wire::Splice.worthwhile?(want.size)

      content = verified_read(want.path, want.digest)
      return if content.nil?

      ops = Wire::Splice.plan(content, base_checksums)
      return if ops.nil?

      Wire::Spliced.new(base_checksums.base, ops)
    end

    private def emit_spliced(
      io : IO,
      want : Wanted,
      spliced : Wire::Spliced,
      codec : Compress::Codec,
      scratch : Bytes,
    ) : Nil
      {% if flag?(:timing) %}
        Wire::Splice.splices_sent += 1
        Wire::Splice.splice_bytes += spliced.ops.size
      {% end %}

      Wire::Binary.write_digest(io, want.digest)
      Wire::ContentKind::Spliced.write(io)
      Wire::Binary.write_digest(io, spliced.base)
      Wire::Chunks.write_all(io, spliced.ops, codec, scratch)
    end

    private def within(digests : Array(Bytes), budget : UInt64) : Array(Wanted)
      wanted = Array(Wanted).new
      spent = 0_u64

      digests.each do |digest|
        located = @locations.locate(digest)
        next if located.nil?

        break if !wanted.empty? && spent + located.size > budget

        wanted << Wanted.new(digest, located.path, located.size)
        spent += located.size
      end

      wanted
    end

    private def prune_kept : Nil
      kept = @kept
      return if kept.nil?

      kept.prune(@locations)
    end

    private def verified_read(path : String, digest : Bytes) : Bytes?
      case (content = @disk.read(path))
      in Problem
        nil
      in Bytes
        content if Core::Digests.matches?(content, digest)
      end
    end
  end
end
