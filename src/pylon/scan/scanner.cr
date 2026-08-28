require "wait_group"
require "../core/entry"
require "../core/paths"
require "./cache_entry"
require "./tally"
require "./ignores"
require "./snapshot"

module Pylon::Scan
  struct Scanner(F)
    READ_BUFFER_BYTES      = 64 * 1024
    DEFAULT_GRANULARITY_NS = 1_000_000_000_i64
    DEFAULT_PARALLELISM    = System.cpu_count.to_i * 2

    @next_cache : Cache
    @dirty : Set(String)

    private record Surveyed,
      kind : Core::Entry::Kind,
      metadata : Metadata? = nil,
      target : String? = nil

    private class Survey
      getter nodes = {} of String => Surveyed
      getter children = {} of String => Array(String)
      getter pending = [] of String
      getter reused = {} of String => Bytes
      getter carried = {} of String => Core::Entry
    end

    def initialize(
      @filesystem : F,
      @cache : Cache,
      @now_ns : Int64,
      @ignores : Ignores = Ignores::NONE,
      @granularity_ns : Int64 = DEFAULT_GRANULARITY_NS,
      @parallelism : Int32 = DEFAULT_PARALLELISM,
      @baseline : Core::Entry? = nil,
      @recheck : Set(String) = Set(String).new,
      @tally : Tally = Tally.new,
    )
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
        survey.nodes[path] = Surveyed.new(kind: :untracked)
        return
      end

      observed = @filesystem.metadata(path)
      return if observed.nil?

      case observed.kind
      in .directory?
        survey.nodes[path] = Surveyed.new(kind: :directory)
        names = [] of String
        baseline_contents = baseline.try { |entry| entry.directory? ? entry.contents : nil }

        @filesystem.each_child(path) do |name|
          child = Core::Paths.join(path, name)
          look(survey, child, baseline_contents.try(&.[name]?))
          names << name if survey.nodes.has_key?(child) || survey.carried.has_key?(child)
        end

        survey.children[path] = names
      in .file?
        survey.nodes[path] = Surveyed.new(kind: :file, metadata: observed)
        @tally.saw_file

        if (digest = @cache[path]?.try(&.reuse(observed, @now_ns, @granularity_ns)))
          survey.reused[path] = digest
        else
          survey.pending << path
        end
      in .symbolic_link?
        survey.nodes[path] = Surveyed.new(
          kind: :symbolic_link,
          target: @filesystem.link_target(path),
        )
      in .untracked?, .problematic?
        survey.nodes[path] = Surveyed.new(kind: :untracked)
      end
    end

    private def carry_cache(path : String, entry : Core::Entry) : Nil
      if entry.kind.file?
        if (cached = @cache[path]?)
          @next_cache[path] = cached
        end

        return
      end

      entry.contents.each { |name, child| carry_cache(Core::Paths.join(path, name), child) }
    end

    private def hash_pending(survey : Survey, digests : Hash(String, Bytes)) : Nil
      pending = survey.pending
      return if pending.empty?

      workers = Math.min(@parallelism, pending.size)

      if workers <= 1
        buffer = Bytes.new(READ_BUFFER_BYTES)

        pending.each do |path|
          if (digest = @filesystem.digest(path, buffer))
            digests[path] = digest
            @tally.hashed(weight(survey, path))
          end
        end

        return
      end

      partials = Array.new(workers) { {} of String => Bytes }
      context = Fiber::ExecutionContext::Parallel.new("scan-digest", workers)
      waiting = WaitGroup.new(workers)

      workers.times do |worker|
        hash_slice(context, waiting, survey, pending, partials[worker], worker, workers)
      end

      waiting.wait
      partials.each { |partial| digests.merge!(partial) }
    end

    private def hash_slice(
      context : Fiber::ExecutionContext::Parallel,
      waiting : WaitGroup,
      survey : Survey,
      pending : Array(String),
      into : Hash(String, Bytes),
      offset : Int32,
      stride : Int32,
    ) : Nil
      filesystem = @filesystem
      tally = @tally

      context.spawn do
        begin
          buffer = Bytes.new(READ_BUFFER_BYTES)
          index = offset

          while index < pending.size
            path = pending[index]

            if (digest = filesystem.digest(path, buffer))
              into[path] = digest
              tally.hashed(weight(survey, path))
            end

            index += stride
          end
        ensure
          waiting.done
        end
      end
    end

    private def weight(survey : Survey, path : String) : Int64
      survey.nodes[path]?.try(&.metadata).try(&.size.to_i64) || 0_i64
    end

    private def build(survey : Survey, digests : Hash(String, Bytes), path : String) : Core::Entry?
      if (carried = survey.carried[path]?)
        return carried
      end

      node = survey.nodes[path]?
      return nil if node.nil?

      case node.kind
      in .directory?
        contents = {} of String => Core::Entry

        survey.children[path]?.try &.each do |name|
          if (child = build(survey, digests, Core::Paths.join(path, name)))
            contents[name] = child
          end
        end

        Core::Entry.directory(contents)
      in .file?
        observed = node.metadata
        digest = digests[path]?

        return Core::Entry.problematic("unreadable") if observed.nil? || digest.nil?

        @next_cache[path] = CacheEntry.new(observed, digest)

        Core::Entry.file(digest, executable: observed.executable?)
      in .symbolic_link?
        target = node.target

        return Core::Entry.problematic("unreadable link") if target.nil?

        Core::Entry.symlink(target)
      in .untracked?
        Core::Entry.untracked
      in .problematic?
        Core::Entry.problematic("unreadable")
      end
    end
  end
end
