require "sync"
require "../core/digests"
require "../filesystem"
require "../missing"
require "../problem"
require "../wire"

module Pylon::Session
  class ContentStore
    ORPHAN_LIMIT  = 20_000
    PROBE_PREFIX  = "probe-"
    PROBE_CONTENT = "pylon snapshot probe".to_slice

    record Unavailable, reason : String

    def self.open(directory : String, root : String) : ContentStore | Unavailable
      if (blocked = Filesystem.ensure_directory(directory))
        return Unavailable.new("the directory #{directory} could not be created: #{blocked.reason}")
      end

      if (blocked = probe(directory))
        return Unavailable.new("the filesystem under #{directory} cannot snapshot files: #{blocked.reason}")
      end

      held = Set(Bytes).new

      listed = Filesystem.each_child(directory) do |name|
        digest = name.hexbytes?
        held << digest if digest && digest.size == Wire::DIGEST_BYTES
      end

      case listed
      in Missing then Unavailable.new("the directory #{directory} vanished while it was being opened")
      in Problem then Unavailable.new("the directory #{directory} could not be listed: #{listed.reason}")
      in Nil     then new(directory, root, held)
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

    private def initialize(@directory : String, @root : String, @held : Set(Bytes)) : Nil
      @order = Deque(Bytes).new(@held.size)
      @held.each { |digest| @order.push(digest) }
      @lock = Sync::Mutex.new
    end

    def keep(relative_path : String, digest : Bytes) : Nil
      return if @lock.synchronize { @held.includes?(digest) }
      return if Filesystem.snapshot(File.join(@root, relative_path), path_for(digest))

      @lock.synchronize do
        next unless @held.add?(digest)

        @order.push(digest)
      end
    end

    def holds?(digest : Bytes) : Bool
      @lock.synchronize { @held.includes?(digest) }
    end

    def available(digests : Array(Bytes)) : Array(Bytes)
      @lock.synchronize { digests.select { |digest| @held.includes?(digest) } }
    end

    def content(digest : Bytes) : Bytes?
      return unless holds?(digest)

      found = verified_content(digest)
      discard(digest) if found.nil?
      found
    end

    def prune(& : Bytes -> Bool) : Nil
      @lock.synchronize do
        return if @held.size <= ORPHAN_LIMIT

        orphans = @order.count { |digest| @held.includes?(digest) && !yield(digest) }

        while orphans > ORPHAN_LIMIT && (oldest = @order.shift?)
          next unless @held.includes?(oldest)

          if yield(oldest)
            @order.push(oldest)
          else
            @held.delete(oldest)
            Filesystem.delete(path_for(oldest))
            orphans -= 1
          end
        end
      end
    end

    private def discard(digest : Bytes) : Nil
      Filesystem.delete(path_for(digest))
      @lock.synchronize { @held.delete(digest) }
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
