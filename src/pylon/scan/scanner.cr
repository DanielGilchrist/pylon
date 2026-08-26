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

    def initialize(
      @filesystem : F,
      @cache : Cache,
      @now_ns : Int64,
      @ignores : Ignores = Ignores::NONE,
      @granularity_ns : Int64 = DEFAULT_GRANULARITY_NS,
    )
      @next_cache = Cache.new
    end

    def scan : Snapshot
      Snapshot.new(visit(""), @next_cache)
    end

    private def visit(path : String) : Core::Entry?
      return Core::Entry.untracked if @ignores.ignore?(path)

      observed = @filesystem.metadata(path)
      return nil if observed.nil?

      case observed.kind
      in Core::Entry::Kind::Directory    then directory(path)
      in Core::Entry::Kind::File         then file(path, observed)
      in Core::Entry::Kind::SymbolicLink then symlink(path)
      in Core::Entry::Kind::Untracked    then Core::Entry.untracked
      in Core::Entry::Kind::Problematic  then Core::Entry.problematic("unreadable")
      end
    end

    private def directory(path : String) : Core::Entry
      contents = {} of String => Core::Entry

      @filesystem.each_child(path) do |name|
        if (child = visit(join(path, name)))
          contents[name] = child
        end
      end

      Core::Entry.directory(contents)
    end

    private def file(path : String, observed : Metadata) : Core::Entry
      digest = @cache[path]?.try(&.reuse(observed, @now_ns, @granularity_ns))
      digest ||= @filesystem.digest(path)

      return Core::Entry.problematic("unreadable") if digest.nil?

      @next_cache[path] = CacheEntry.new(observed, digest)

      Core::Entry.file(digest, executable: observed.executable?)
    end

    private def symlink(path : String) : Core::Entry
      target = @filesystem.link_target(path)

      return Core::Entry.problematic("unreadable link") if target.nil?

      Core::Entry.symlink(target)
    end

    private def join(path : String, name : String) : String
      path.empty? ? name : "#{path}/#{name}"
    end
  end
end
