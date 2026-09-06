require "digest/sha256"

module Pylon::Scan
  struct Scanner(F, K)
    READ_BUFFER_BYTES   = 64 * 1024
    MEBIBYTE            = 1024 * 1024
    DEFAULT_PARALLELISM = System.cpu_count.to_i * 2

    private alias Surveyed = SurveyedDirectory |
                             SurveyedFile |
                             Core::SymbolicLink |
                             Core::Untracked |
                             Core::Problematic

    @removed : Hash(String, CacheEntry)
    @updated : Array(String)
    @forgetting : Array(Forgetting)
    @dirty : Set(String)

    def initialize(
      @filesystem : F,
      @cache : Cache,
      @now_ns : Int64,
      @ignores : Ignores,
      @previous_tree : Core::Entry?,
      @recheck : Set(String),
      @scanned : Progress,
      @keeper : K,
      @parallelism : Int32 = DEFAULT_PARALLELISM,
    ) : Nil
      @removed = Hash(String, CacheEntry).new
      @updated = Array(String).new
      @forgetting = Array(Forgetting).new
      @dirty = with_ancestors(@recheck)
    end

    def scan : Snapshot
      previous_tree = @previous_tree

      if previous_tree && @recheck.empty?
        return Snapshot.new(previous_tree, @cache, @removed, @updated)
      end

      findings = Findings.new
      survey(findings, "", previous_tree)

      digests = findings.cached_digests
      hash_pending(findings, digests)
      forget_vanished(findings)

      Snapshot.new(build(findings, digests, ""), @cache, @removed, @updated)
    end

    private def with_ancestors(recheck : Set(String)) : Set(String)
      dirty = Set(String).new

      recheck.each do |path|
        dirty << path
        offset = 0

        while (separator = path.index('/', offset))
          dirty << path[0, separator]
          offset = separator + 1
        end
      end

      dirty << ""
      dirty
    end

    private def trusted?(path : String) : Bool
      !@previous_tree.nil? && !@dirty.includes?(path)
    end

    private def survey(findings : Findings, path : String, previous : Core::Entry?) : Nil
      if previous && trusted?(path)
        findings.trusted[path] = previous
        return
      end

      if @ignores.ignore?(path)
        findings.nodes[path] = Core::Untracked.new
        return
      end

      case (observed = @filesystem.metadata(path))
      in Nil
        @forgetting << Forgetting.new(path, previous)
        return
      in Problem
        findings.nodes[path] = Core::Problematic.new(observed.reason)
        @forgetting << Forgetting.new(path, previous)
        return
      in Metadata
      end

      @forgetting << Forgetting.new(path, nil)

      case observed.kind
      in .directory?
        findings.nodes[path] = SurveyedDirectory.new
        names = Set(String).new
        previous_contents = previous.contents if previous.is_a?(Core::Directory)

        listed = @filesystem.each_child(path) do |name|
          child = Core::Paths.join(path, name)
          survey(findings, child, previous_contents.try(&.[name]?))
          names << name if findings.nodes.has_key?(child) || findings.trusted.has_key?(child)
        end

        case listed
        in Nil
          findings.children[path] = names
          previous_contents.try &.each do |name, child|
            next if names.includes?(name)

            @forgetting << Forgetting.new(Core::Paths.join(path, name), child)
          end
        in Missing
          findings.nodes.delete(path)
          @forgetting << Forgetting.new(path, previous)
        in Problem
          findings.nodes[path] = Core::Problematic.new(listed.reason)
          @forgetting << Forgetting.new(path, previous)
        end
      in .file?
        if observed.size > Wire::MAX_CONTENT_BYTES
          size_mib = (observed.size / MEBIBYTE).round(1)
          limit_mib = Wire::MAX_CONTENT_BYTES // MEBIBYTE
          findings.nodes[path] = Core::Problematic.new(
            "the file is #{size_mib} MiB and the limit is #{limit_mib} MiB",
          )
          return
        end

        findings.nodes[path] = SurveyedFile.new(observed)
        @scanned.add_file

        if (digest = reusable_digest(findings, path, observed))
          findings.cached_digests[path] = digest
        else
          findings.to_hash << PendingFile.new(path, observed.size.to_i64)
        end
      in .symbolic_link?
        findings.nodes[path] = link(@filesystem.link_target(path))
      in .untracked?
        findings.nodes[path] = Core::Untracked.new
      end
    end

    private def reusable_digest(findings : Findings, path : String, observed : Metadata) : Bytes?
      if (cached = @cache[path]?)
        return cached.reuse(observed, @now_ns, Metadata::GRANULARITY_NS)
      end

      relocated = @cache.relocated(observed.inode)
      return if relocated.nil?

      relocated.reuse(observed, @now_ns, Metadata::GRANULARITY_NS)
    end

    private def forget(path : String) : Nil
      entry = @cache.forget(path)
      @removed[path] = entry if entry
    end

    private def forget_vanished(findings : Findings) : Nil
      if @previous_tree
        @forgetting.each { |forgetting| forget_subtree(forgetting.path, forgetting.previous) }
      else
        stale = Array(String).new
        @cache.each { |path, _| stale << path unless findings.nodes[path]?.is_a?(SurveyedFile) }
        stale.each { |path| forget(path) }
      end
    end

    private def forget_subtree(path : String, previous : Core::Entry?) : Nil
      forget(path)
      return unless previous.is_a?(Core::Directory)

      previous.contents.each do |name, child|
        forget_subtree(Core::Paths.join(path, name), child)
      end
    end

    private def hash_pending(findings : Findings, digests : Hash(String, Bytes | Problem)) : Nil
      pending = findings.to_hash
      return if pending.empty?

      workers = Math.min(@parallelism, pending.size)

      if workers <= 1
        hash_slice(findings, pending, digests, 0, 1)
        return
      end

      partials = Array.new(workers) { Hash(String, Bytes | Problem).new }

      Pylon::Fibers.parallel(:scan_digest, workers) do |worker|
        hash_slice(findings, pending, partials[worker], worker, workers)
      end

      partials.each { |partial| digests.merge!(partial) }
    end

    private def hash_slice(
      findings : Findings,
      pending : Array(PendingFile),
      into : Hash(String, Bytes | Problem),
      offset : Int32,
      stride : Int32,
    ) : Nil
      buffer = Bytes.new(READ_BUFFER_BYTES)
      hasher = Digest::SHA256.new
      index = offset

      while index < pending.size
        file = pending[index]
        digest = @filesystem.digest(file.path, buffer, hasher)
        into[file.path] = digest

        if digest.is_a?(Bytes)
          @scanned.add_bytes(file.size)
          @keeper.keep(file.path, digest)
        end
        index += stride
      end
    end

    private def build(
      findings : Findings,
      digests : Hash(String, Bytes | Problem),
      path : String,
    ) : Core::Entry?
      if (carried = findings.trusted[path]?)
        return carried
      end

      node = findings.nodes[path]?
      return if node.nil?

      case node
      in SurveyedDirectory
        contents = Hash(String, Core::Entry).new

        findings.children[path]?.try &.each do |name|
          if (child = build(findings, digests, Core::Paths.join(path, name)))
            contents[name] = child
          end
        end

        Core::Directory.new(contents)
      in SurveyedFile
        case (digest = digests[path]?)
        in Nil
          raise "the scan surveyed #{path.inspect} as a file but computed no digest for it"
        in Problem
          forget(path)
          Core::Problematic.new(digest.reason)
        in Bytes
          entry = CacheEntry.new(
            node.metadata,
            digest,
            freshly_written: node.metadata.freshly_modified?(@now_ns, Metadata::GRANULARITY_NS),
          )
          previous = @cache.store(path, entry)
          @removed[path] = previous if previous && previous.digest != digest
          @updated << path

          Core::File.new(digest, executable: node.metadata.executable?)
        end
      in Core::SymbolicLink, Core::Untracked, Core::Problematic
        node
      end
    end

    private def link(target : String | Problem) : Core::SymbolicLink | Core::Problematic
      case target
      in Problem then Core::Problematic.new("the link target #{target.reason}")
      in String  then Core::SymbolicLink.new(target)
      end
    end

    private record PendingFile, path : String, size : Int64
    private record Forgetting, path : String, previous : Core::Entry?

    private record SurveyedDirectory
    private record SurveyedFile, metadata : Metadata

    private class Findings
      getter nodes = Hash(String, Surveyed).new
      getter children = Hash(String, Set(String)).new
      getter to_hash = Array(PendingFile).new
      getter cached_digests = Hash(String, Bytes | Problem).new
      getter trusted = Hash(String, Core::Entry).new
    end
  end
end
