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

    private record Surveyed,
      kind : Core::Entry::Kind,
      metadata : Metadata? = nil,
      target : String? = nil

    private class Survey
      getter nodes = {} of String => Surveyed
      getter children = {} of String => Array(String)
      getter pending = [] of String
      getter reused = {} of String => Bytes
    end

    def initialize(
      @filesystem : F,
      @cache : Cache,
      @now_ns : Int64,
      @ignores : Ignores = Ignores::NONE,
      @granularity_ns : Int64 = DEFAULT_GRANULARITY_NS,
      @parallelism : Int32 = DEFAULT_PARALLELISM,
    )
      @next_cache = Cache.new
    end

    def scan : Snapshot
      survey = Survey.new
      look(survey, "")

      digests = survey.reused
      hash_pending(survey, digests)

      Snapshot.new(build(survey, digests, ""), @next_cache)
    end

    private def look(survey : Survey, path : String) : Nil
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

        @filesystem.each_child(path) do |name|
          child = join(path, name)
          look(survey, child)
          names << name if survey.nodes.has_key?(child)
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
