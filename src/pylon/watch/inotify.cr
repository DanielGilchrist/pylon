{% skip_file unless flag?(:linux) %}

require "sync"
require "../core/paths"
require "../scan/ignores"
require "./dirty"
require "./lib_inotify"

module Pylon::Watch
  class Inotify
    WATCH_MASK = LibInotify::IN_MODIFY | LibInotify::IN_ATTRIB | LibInotify::IN_CLOSE_WRITE |
                 LibInotify::IN_MOVED_FROM | LibInotify::IN_MOVED_TO | LibInotify::IN_CREATE |
                 LibInotify::IN_DELETE | LibInotify::IN_DELETE_SELF | LibInotify::IN_MOVE_SELF |
                 LibInotify::IN_EXCL_UNLINK | LibInotify::IN_ONLYDIR

    READ_BUFFER_BYTES = 64 * 1024

    getter signals : Channel(Nil)

    def self.open(
      root : String,
      ignores : Array(String),
      signals : Channel(Nil) = Channel(Nil).new(1),
    ) : Inotify?
      descriptor = LibInotify.inotify_init1(LibInotify::IN_CLOEXEC)
      return nil if descriptor < 0

      new(descriptor, root, Scan::Ignores.new(ignores), signals)
    end

    def initialize(descriptor : Int32, @root : String, @ignores : Scan::Ignores, @signals : Channel(Nil))
      @descriptor = descriptor
      @paths = {} of Int32 => String
      @dirty = Set(String).new
      @lock = Sync::Mutex.new
      @fresh = false
      @stopping = false

      watch_tree("")

      # the read blocks its thread, which is precisely what an isolated
      # context is for; an inotify fd cannot be driven by the event loop
      @context = Fiber::ExecutionContext::Isolated.new("inotify") { listen }
    end

    def drain : Dirty
      @lock.synchronize do
        dirty = @fresh ? Everything.new : Touched.new(@dirty.to_a)
        @dirty.clear
        @fresh = false
        dirty
      end
    end

    def close : Nil
      @stopping = true
      LibC.close(@descriptor)
    end

    private def watch_tree(relative : String) : Nil
      return if @ignores.ignore?(relative)

      add_watch(relative)

      Dir.each_child(absolute(relative)) do |name|
        child = Core::Paths.join(relative, name)
        next unless Dir.exists?(absolute(child))

        watch_tree(child)
      end
    rescue File::Error
      nil
    end

    private def add_watch(relative : String) : Nil
      wd = LibInotify.inotify_add_watch(@descriptor, absolute(relative).check_no_null_byte, WATCH_MASK)
      return if wd < 0

      @paths[wd] = relative
    end

    private def listen : Nil
      buffer = Bytes.new(READ_BUFFER_BYTES)

      until @stopping
        read = LibC.read(@descriptor, buffer.to_unsafe.as(Void*), LibC::SizeT.new(buffer.size))
        break if read <= 0

        consume(buffer[0, read])
        signal
      end
    end

    private def consume(bytes : Bytes) : Nil
      offset = 0

      while offset + sizeof(LibInotify::Event) <= bytes.size
        event = bytes[offset, sizeof(LibInotify::Event)].to_unsafe.as(LibInotify::Event*).value
        break if offset + sizeof(LibInotify::Event) + event.len > bytes.size

        name_bytes = bytes[offset + sizeof(LibInotify::Event), event.len]
        offset += sizeof(LibInotify::Event) + event.len

        record(event, name_of(name_bytes))
      end
    end

    private def name_of(bytes : Bytes) : String
      terminator = bytes.index(0_u8) || bytes.size
      String.new(bytes[0, terminator])
    end

    private def record(event : LibInotify::Event, name : String) : Nil
      if event.mask & LibInotify::IN_Q_OVERFLOW != 0
        @lock.synchronize { @fresh = true }
        return
      end

      if event.mask & LibInotify::IN_IGNORED != 0
        @paths.delete(event.wd)
        return
      end

      directory = @paths[event.wd]?
      return if directory.nil?

      path = name.empty? ? directory : Core::Paths.join(directory, name)
      return if @ignores.ignore?(path)

      @lock.synchronize { @dirty << path }

      return unless event.mask & LibInotify::IN_ISDIR != 0
      return unless event.mask & (LibInotify::IN_CREATE | LibInotify::IN_MOVED_TO) != 0

      watch_tree(path)
      mark_contents(path)
    end

    private def mark_contents(relative : String) : Nil
      Dir.each_child(absolute(relative)) do |name|
        child = Core::Paths.join(relative, name)
        next if @ignores.ignore?(child)

        @lock.synchronize { @dirty << child }
        mark_contents(child) if Dir.exists?(absolute(child))
      end
    rescue File::Error
      nil
    end

    private def signal : Nil
      select
      when @signals.send(nil)
      else
      end
    end

    private def absolute(relative : String) : String
      relative.empty? ? @root : File.join(@root, relative)
    end
  end
end
