require "wait_group"
require "../core/entry"
require "./cache_entry"
require "./ignores"

module Pylon::Scan
  alias Cache = Hash(String, CacheEntry)

  struct Snapshot
    getter root : Core::Entry?
    getter cache : Cache

    def initialize(@root : Core::Entry?, @cache : Cache)
    end
  end

  struct Scanner(F)
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
        survey.nodes[path] = Surveyed.new(kind: Core::Entry::Kind::Untracked)
        return
      end

      observed = @filesystem.metadata(path)
      return if observed.nil?

      case observed.kind
      in Core::Entry::Kind::Directory
        survey.nodes[path] = Surveyed.new(kind: Core::Entry::Kind::Directory)
        names = [] of String
        baseline_contents = baseline.try { |entry| entry.directory? ? entry.contents : nil }

        @filesystem.each_child(path) do |name|
          child = join(path, name)
          look(survey, child, baseline_contents.try(&.[name]?))
          names << name if survey.nodes.has_key?(child) || survey.carried.has_key?(child)
        end

        survey.children[path] = names
      in Core::Entry::Kind::File
        survey.nodes[path] = Surveyed.new(kind: Core::Entry::Kind::File, metadata: observed)

        if (digest = @cache[path]?.try(&.reuse(observed, @now_ns, @granularity_ns)))
          survey.reused[path] = digest
        else
          survey.pending << path
        end
      in Core::Entry::Kind::SymbolicLink
        survey.nodes[path] = Surveyed.new(
          kind: Core::Entry::Kind::SymbolicLink,
          target: @filesystem.link_target(path),
        )
      in Core::Entry::Kind::Untracked, Core::Entry::Kind::Problematic
        survey.nodes[path] = Surveyed.new(kind: Core::Entry::Kind::Untracked)
      end
    end

    private def carry_cache(path : String, entry : Core::Entry) : Nil
      if entry.kind.file?
        if (cached = @cache[path]?)
          @next_cache[path] = cached
        end

        return
      end

      entry.contents.each { |name, child| carry_cache(join(path, name), child) }
    end

    private def hash_pending(survey : Survey, digests : Hash(String, Bytes)) : Nil
      pending = survey.pending
      return if pending.empty?

      workers = Math.min(@parallelism, pending.size)

      if workers <= 1
        pending.each do |path|
          if (digest = @filesystem.digest(path))
            digests[path] = digest
          end
        end

        return
      end

      partials = Array.new(workers) { {} of String => Bytes }
      context = Fiber::ExecutionContext::Parallel.new("scan-digest", workers)
      waiting = WaitGroup.new(workers)

      workers.times do |worker|
        context.spawn do
          begin
            local = partials[worker]
            index = worker

            while index < pending.size
              path = pending[index]

              if (digest = @filesystem.digest(path))
                local[path] = digest
              end

              index += workers
            end
          ensure
            waiting.done
          end
        end
      end

      waiting.wait
      partials.each { |partial| digests.merge!(partial) }
    end

    private def build(survey : Survey, digests : Hash(String, Bytes), path : String) : Core::Entry?
      if (carried = survey.carried[path]?)
        return carried
      end

      node = survey.nodes[path]?
      return nil if node.nil?

      case node.kind
      in Core::Entry::Kind::Directory
        contents = {} of String => Core::Entry

        survey.children[path]?.try &.each do |name|
          if (child = build(survey, digests, join(path, name)))
            contents[name] = child
          end
        end

        Core::Entry.directory(contents)
      in Core::Entry::Kind::File
        observed = node.metadata
        digest = digests[path]?

        return Core::Entry.problematic("unreadable") if observed.nil? || digest.nil?

        @next_cache[path] = CacheEntry.new(observed, digest)

        Core::Entry.file(digest, executable: observed.executable?)
      in Core::Entry::Kind::SymbolicLink
        target = node.target

        return Core::Entry.problematic("unreadable link") if target.nil?

        Core::Entry.symlink(target)
      in Core::Entry::Kind::Untracked
        Core::Entry.untracked
      in Core::Entry::Kind::Problematic
        Core::Entry.problematic("unreadable")
      end
    end

    private def join(path : String, name : String) : String
      path.empty? ? name : "#{path}/#{name}"
    end
  end
end
