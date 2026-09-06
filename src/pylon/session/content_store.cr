require "sync"

module Pylon::Session
  class ContentStore
    ORPHAN_LIMIT  = 20_000
    PROBE_PREFIX  = "probe-"
    PROBE_CONTENT = "pylon snapshot probe".to_slice

    def self.open(directory : String, root : String) : ContentStore | Problem
      if (blocked = Filesystem.ensure_directory(directory))
        return Problem.new("the directory #{directory} could not be created: #{blocked.reason}")
      end

      if (blocked = probe(directory))
        return Problem.new(
          "the filesystem under #{directory} cannot snapshot files: #{blocked.reason}",
        )
      end

      kept = Kept.new

      listed = Filesystem.each_child(directory) do |name|
        digest = name.hexbytes?
        kept.add(digest) if digest && digest.size == Wire::DIGEST_BYTES
      end

      case listed
      in Missing
        Problem.new("the directory #{directory} vanished while it was being opened")
      in Problem
        Problem.new("the directory #{directory} could not be listed: #{listed.reason}")
      in Nil then new(directory, root, kept)
      end
    end

    private def self.probe(directory : String) : Problem?
      probe = File.join(directory, "#{PROBE_PREFIX}#{Random::Secure.hex(8)}")
      copy = "#{probe}-copy"

      if (blocked = Filesystem.write(probe, PROBE_CONTENT))
        return blocked
      end

      blocked = Filesystem.snapshot(probe, copy)
      Filesystem.delete(copy)
      Filesystem.delete(probe)
      blocked
    end

    private def initialize(@directory : String, @root : String, @kept : Kept) : Nil
      @lock = Sync::Mutex.new
    end

    def keep(relative_path : String, digest : Bytes) : Nil
      return if @lock.synchronize { @kept.includes?(digest) }
      return if Filesystem.snapshot(File.join(@root, relative_path), path_for(digest))

      @lock.synchronize { @kept.add(digest) }
    end

    def holds?(digest : Bytes) : Bool
      @lock.synchronize { @kept.includes?(digest) }
    end

    def held(digests : Array(Bytes)) : Array(Bytes)
      @lock.synchronize { digests.select { |digest| @kept.includes?(digest) } }
    end

    def content(digest : Bytes) : Bytes?
      return unless holds?(digest)

      found = verified_content(digest)
      @lock.synchronize { discard([digest]) } if found.nil?
      found
    end

    def prune(live : Locations) : Nil
      @lock.synchronize { discard(@kept.surplus(live, bound: ORPHAN_LIMIT)) }
    end

    # Callers hold the lock.
    private def discard(digests : Array(Bytes)) : Nil
      digests.each { |digest| Filesystem.delete(path_for(digest)) }
      @kept.delete_all(digests)
    end

    private def path_for(digest : Bytes) : String
      File.join(@directory, digest.hexstring)
    end

    private def verified_content(digest : Bytes) : Bytes?
      opened = Filesystem.open(path_for(digest)) do |file|
        content = Bytes.new(file.size)
        file.read_fully(content)
        content
      end

      case opened
      in Missing, Problem then nil
      in Bytes            then opened if Core::Digests.matches?(opened, digest)
      end
    end
  end
end
