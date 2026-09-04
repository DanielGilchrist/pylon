require "../core/digests"
require "../fibers"
require "../filesystem"
require "../missing"
require "../problem"
require "../wire"

module Pylon::Session
  class ContentStore
    PARALLELISM   = 4
    PROBE_PREFIX  = "probe-"
    PROBE_CONTENT = "pylon clone probe".to_slice

    record Retention, source : String, digest : Bytes
    record Unavailable, reason : String

    def self.open(directory : String) : ContentStore | Unavailable
      if (blocked = Filesystem.ensure_directory(directory))
        return Unavailable.new("the directory #{directory} could not be created: #{blocked.reason}")
      end

      held = Set(Bytes).new

      listed = Filesystem.each_child(directory) do |name|
        digest = name.hexbytes?
        held << digest if digest && digest.size == Wire::DIGEST_BYTES
      end

      case listed
      in Missing then return Unavailable.new("the directory #{directory} vanished while it was being opened")
      in Problem then return Unavailable.new("the directory #{directory} could not be listed: #{listed.reason}")
      in Nil
      end

      if (blocked = clone_probe(directory))
        return Unavailable.new("the filesystem under #{directory} cannot clone files: #{blocked.reason}")
      end

      new(directory, held)
    end

    private def self.clone_probe(directory : String) : Problem?
      probe = File.join(directory, "#{PROBE_PREFIX}#{Random::Secure.hex(8)}")
      copy = "#{probe}-copy"

      if (blocked = Filesystem.write(probe, PROBE_CONTENT))
        return blocked
      end

      blocked = Filesystem.clone(probe, copy)
      Filesystem.delete(copy)
      Filesystem.delete(probe)
      blocked
    end

    private def initialize(@directory : String, @held : Set(Bytes)) : Nil
    end

    def retained?(digest : Bytes) : Bool
      @held.includes?(digest)
    end

    def retain(retentions : Array(Retention)) : Nil
      fresh = retentions.reject { |retention| @held.includes?(retention.digest) }
      return if fresh.empty?

      workers = Math.min(PARALLELISM, fresh.size)
      kept = Array(Array(Bytes)).new(workers) { Array(Bytes).new }

      if workers <= 1
        capture_slice(fresh, kept[0], 0, 1)
      else
        Fibers.parallel(:mirror, workers) { |worker| capture_slice(fresh, kept[worker], worker, workers) }
      end

      kept.each { |slice| slice.each { |digest| @held << digest } }
    end

    def content(digest : Bytes) : Bytes?
      return unless @held.includes?(digest)

      found = verified_content(path_for(digest), digest)
      discard(digest) if found.nil?
      found
    end

    def prune(keep : Set(Bytes)) : Nil
      stale = @held.reject { |digest| keep.includes?(digest) }
      stale.each { |digest| discard(digest) }
    end

    private def capture_slice(fresh : Array(Retention), into : Array(Bytes), offset : Int32, stride : Int32) : Nil
      index = offset

      while index < fresh.size
        captured = capture(fresh[index])
        into << captured if captured
        index += stride
      end
    end

    private def capture(retention : Retention) : Bytes?
      destination = path_for(retention.digest)
      return if Filesystem.clone(retention.source, destination)
      return retention.digest if verified_content(destination, retention.digest)

      Filesystem.delete(destination)
      nil
    end

    private def discard(digest : Bytes) : Nil
      Filesystem.delete(path_for(digest))
      @held.delete(digest)
    end

    private def path_for(digest : Bytes) : String
      File.join(@directory, digest.hexstring)
    end

    private def verified_content(path : String, digest : Bytes) : Bytes?
      opened = Filesystem.open(path) do |file|
        content = Bytes.new(file.size)
        file.read_fully(content)
        content
      end

      case opened
      in Missing, Problem then nil
      in Bytes            then Core::Digests.matches?(opened, digest) ? opened : nil
      end
    end
  end
end
