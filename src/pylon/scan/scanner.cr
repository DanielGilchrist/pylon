require "digest/sha256"
require "../fibers"
require "../filesystem"
require "../wire"
require "../core/entry"
require "../core/paths"
require "./cache_entry"
require "./tally"
require "./ignores"
require "./snapshot"

module Pylon::Scan
  struct Scanner(F, K)
    READ_BUFFER_BYTES   = 64 * 1024
    MEBIBYTE            = 1024 * 1024
    DEFAULT_PARALLELISM = System.cpu_count.to_i * 2

    private alias Surveyed = SurveyedDirectory |
                             SurveyedFile |
                             SurveyedLink |
                             SurveyedUntracked |
                             SurveyedProblem

    @next_cache : Cache
    @dirty : Set(String)

    def initialize(
      @filesystem : F,
      @cache : Cache,
      @now_ns : Int64,
      @ignores : Ignores,
      @baseline : Core::Entry?,
      @recheck : Set(String),
      @tally : Tally,
      @keeper : K,
      @parallelism : Int32 = DEFAULT_PARALLELISM,
    ) : Nil
      @next_cache = Cache.new
      @dirty = expand(@recheck)
    end

    def scan : Snapshot
      baseline = @baseline

      return Snapshot.new(baseline, @cache) if baseline && @recheck.empty?

      survey = Survey.new
      look(survey, "", baseline)

      digests = survey.reused
      hash_pending(survey, digests)

      Snapshot.new(build(survey, digests, ""), @next_cache)
    end

    private def expand(recheck : Set(String)) : Set(String)
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
      !@baseline.nil? && !@dirty.includes?(path)
    end

    private def look(survey : Survey, path : String, baseline : Core::Entry?) : Nil
      if baseline && trusted?(path)
        survey.carried[path] = baseline
        carry_cache(path, baseline)
        return
      end

      if @ignores.ignore?(path)
        survey.nodes[path] = SurveyedUntracked.new
        return
      end

      case (observed = @filesystem.metadata(path))
      in Nil
        return
      in Problem
        survey.nodes[path] = SurveyedProblem.new(observed.reason)
        return
      in Metadata
      end

      case observed.kind
      in .directory?
        survey.nodes[path] = SurveyedDirectory.new
        names = Array(String).new
        baseline_contents = baseline.contents if baseline.is_a?(Core::Directory)

        listed = @filesystem.each_child(path) do |name|
          child = Core::Paths.join(path, name)
          look(survey, child, baseline_contents.try(&.[name]?))
          names << name if survey.nodes.has_key?(child) || survey.carried.has_key?(child)
        end

        case listed
        in Nil
          survey.children[path] = names
        in Missing
          survey.nodes.delete(path)
        in Problem
          survey.nodes[path] = SurveyedProblem.new(listed.reason)
        end
      in .file?
        if observed.size > Wire::MAX_CONTENT_BYTES
          size_mib = (observed.size / MEBIBYTE).round(1)
          limit_mib = Wire::MAX_CONTENT_BYTES // MEBIBYTE
          survey.nodes[path] = SurveyedProblem.new(
            "the file is #{size_mib} MiB and the limit is #{limit_mib} MiB",
          )
          return
        end

        survey.nodes[path] = SurveyedFile.new(observed)
        @tally.saw_file

        if (digest = reusable_digest(survey, path, observed))
          survey.reused[path] = digest
        else
          survey.pending << PendingFile.new(path, observed.size.to_i64)
        end
      in .symbolic_link?
        survey.nodes[path] = SurveyedLink.new(@filesystem.link_target(path))
      in .untracked?
        survey.nodes[path] = SurveyedUntracked.new
      end
    end

    private def reusable_digest(survey : Survey, path : String, observed : Metadata) : Bytes?
      if (cached = @cache[path]?)
        return cached.reuse(observed, @now_ns, Metadata::GRANULARITY_NS)
      end

      relocated = survey.by_inode(@cache)[observed.inode]?
      return if relocated.nil?

      relocated.reuse(observed, @now_ns, Metadata::GRANULARITY_NS)
    end

    private def carry_cache(path : String, entry : Core::Entry) : Nil
      case entry
      in Core::File
        if (cached = @cache[path]?)
          @next_cache[path] = cached
        end
      in Core::Directory
        entry.contents.each { |name, child| carry_cache(Core::Paths.join(path, name), child) }
      in Core::SymbolicLink, Core::Untracked, Core::Problematic
        nil
      end
    end

    private def hash_pending(survey : Survey, digests : Hash(String, Bytes | Problem)) : Nil
      pending = survey.pending
      return if pending.empty?

      workers = Math.min(@parallelism, pending.size)

      if workers <= 1
        hash_slice(survey, pending, digests, 0, 1)
        return
      end

      partials = Array.new(workers) { Hash(String, Bytes | Problem).new }

      Pylon::Fibers.parallel(:scan_digest, workers) do |worker|
        hash_slice(survey, pending, partials[worker], worker, workers)
      end

      partials.each { |partial| digests.merge!(partial) }
    end

    private def hash_slice(
      survey : Survey,
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
          @tally.hashed(file.size)
          @keeper.keep(file.path, digest)
        end
        index += stride
      end
    end

    private def build(
      survey : Survey,
      digests : Hash(String, Bytes | Problem),
      path : String,
    ) : Core::Entry?
      if (carried = survey.carried[path]?)
        return carried
      end

      node = survey.nodes[path]?
      return if node.nil?

      case node
      in SurveyedDirectory
        contents = Hash(String, Core::Entry).new

        survey.children[path]?.try &.each do |name|
          if (child = build(survey, digests, Core::Paths.join(path, name)))
            contents[name] = child
          end
        end

        Core::Directory.new(contents)
      in SurveyedFile
        case (digest = digests[path]?)
        in Nil
          raise "the scan surveyed #{path.inspect} as a file but computed no digest for it"
        in Problem
          Core::Problematic.new(digest.reason)
        in Bytes
          @next_cache[path] = CacheEntry.new(
            node.metadata,
            digest,
            provisional: node.metadata.freshly_modified?(@now_ns, Metadata::GRANULARITY_NS),
          )

          Core::File.new(digest, executable: node.metadata.executable?)
        end
      in SurveyedLink
        case (target = node.target)
        in Problem
          Core::Problematic.new("the link target #{target.reason}")
        in String
          Core::SymbolicLink.new(target)
        end
      in SurveyedUntracked
        Core::Untracked.new
      in SurveyedProblem
        Core::Problematic.new(node.reason)
      end
    end

    private record PendingFile, path : String, size : Int64

    private record SurveyedDirectory
    private record SurveyedFile, metadata : Metadata
    private record SurveyedLink, target : String | Problem
    private record SurveyedUntracked
    private record SurveyedProblem, reason : String

    private class Survey
      @by_inode : Hash(UInt64, CacheEntry)? = nil

      getter nodes = Hash(String, Surveyed).new
      getter children = Hash(String, Array(String)).new
      getter pending = Array(PendingFile).new
      getter reused = Hash(String, Bytes | Problem).new
      getter carried = Hash(String, Core::Entry).new

      def by_inode(cache : Cache) : Hash(UInt64, CacheEntry)
        @by_inode ||= index_inodes(cache)
      end

      private def index_inodes(cache : Cache) : Hash(UInt64, CacheEntry)
        indexed = Hash(UInt64, CacheEntry).new(initial_capacity: cache.size)
        cache.each_value { |entry| indexed[entry.metadata.inode] = entry }
        indexed
      end
    end
  end
end
