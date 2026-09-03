{% skip_file unless flag?(:linux) %}

require "sync"
require "../brand"
require "../core/paths"
require "../fibers"
require "../filesystem"
require "../scan/ignores"
require "./dirty"
require "./unavailable"
require "./walk"
require "./lib_inotify"

module Pylon::Watch
  class Inotify
    include Walk

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
      *,
      brand : Brand,
    ) : Inotify | Unavailable
      descriptor = LibInotify.inotify_init1(LibInotify::IN_CLOEXEC)
      return Unavailable.new("inotify could not be initialised: #{Errno.value}") if descriptor < 0

      wake = StaticArray(LibC::Int, 2).new(0)

      if LibC.pipe(wake) < 0
        failed = Errno.value
        LibC.close(descriptor)
        return Unavailable.new("the wake pipe could not be created: #{failed}")
      end

      watcher = new(descriptor, wake[0], wake[1], root, Scan::Ignores.new(ignores), signals, brand)
      return watcher if watcher.watching?

      watcher.close
      Unavailable.new("the sync root could not be watched (inotify watch limit?)")
    end

    def initialize(
      descriptor : Int32,
      wake_read : Int32,
      wake_write : Int32,
      @root : String,
      @ignores : Scan::Ignores,
      @signals : Channel(Nil),
      @brand : Brand,
    ) : Nil
      @descriptor = descriptor
      @wake_read = wake_read
      @wake_write = wake_write
      @paths = Hash(Int32, String).new
      @dirty = Set(String).new
      @lock = Sync::Mutex.new
      @fresh = false
      @stopping = false
      @done = Channel(Nil).new
      @missed = false

      watch_tree("")

      # the read blocks its thread, which is precisely what an isolated
      # context is for; an inotify fd cannot be driven by the event loop
      @context = Fibers.isolated(:inotify) { listen }
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
      return if @stopping

      @stopping = true
      wake = 1_u8
      LibC.write(@wake_write, pointerof(wake).as(Void*), LibC::SizeT.new(1))
      @done.receive?
      LibC.close(@descriptor)
      LibC.close(@wake_read)
      LibC.close(@wake_write)
    end

    private def watch_tree(relative : String) : Nil
      return if @ignores.ignore?(relative)

      add_watch(relative)

      walk(absolute(relative)) do |name|
        child = Core::Paths.join(relative, name)
        next unless Dir.exists?(absolute(child))

        watch_tree(child)
      end
    end

    def watching? : Bool
      @paths.has_value?("")
    end

    private def add_watch(relative : String) : Nil
      wd = LibInotify.inotify_add_watch(@descriptor, absolute(relative).check_no_null_byte, WATCH_MASK)

      if wd < 0
        unless @missed || relative.empty?
          @missed = true
          STDERR.puts(@brand.prefix("some directories could not be watched (inotify watch limit?), changes in them will not be noticed"))
        end

        return
      end

      @paths[wd] = relative
    end

    private def listen : Nil
      buffer = Bytes.new(READ_BUFFER_BYTES)

      while awaited?
        read = LibC.read(@descriptor, buffer.to_unsafe.as(Void*), LibC::SizeT.new(buffer.size))
        break if read <= 0

        consume(buffer[0, read])
        signal
      end
    ensure
      @done.close
    end

    private def awaited? : Bool
      loop do
        return false if @stopping

        watched = StaticArray[poll_readable(@descriptor), poll_readable(@wake_read)]
        ready = LibInotify.poll(watched.to_unsafe, LibC::ULong.new(2), -1)

        next if ready < 0 && Errno.value.eintr?
        return false if ready < 0
        return false if watched[1].revents != 0
        return true if watched[0].revents != 0
      end
    end

    private def poll_readable(descriptor : Int32) : LibInotify::PollDescriptor
      watched = LibInotify::PollDescriptor.new
      watched.fd = descriptor
      watched.events = LibInotify::POLLIN
      watched
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
      walk(absolute(relative)) do |name|
        child = Core::Paths.join(relative, name)
        next if @ignores.ignore?(child)

        @lock.synchronize { @dirty << child }
        mark_contents(child) if Dir.exists?(absolute(child))
      end
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
