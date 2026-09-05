{% skip_file unless flag?(:darwin) %}

require "../fibers"
require "../filesystem"
require "../problem"
require "../scan/ignores"
require "./dirty_paths"
require "./lib_fsevents"

module Pylon::Watch
  class FSEvents
    LATENCY_SECONDS   = 0.01
    STOP_POLL_SECONDS =  0.5

    FRESH_FLAGS = LibFSEvents::MUST_SCAN_SUBDIRS |
                  LibFSEvents::USER_DROPPED |
                  LibFSEvents::KERNEL_DROPPED |
                  LibFSEvents::IDS_WRAPPED |
                  LibFSEvents::ROOT_CHANGED

    CALLBACK = LibFSEvents::Callback.new do |_stream, info, count, paths, flags, _identifiers|
      Box(FSEvents).unbox(info).consume(count, paths, flags)
    end

    enum Start
      Running
      CreateFailed
      StartFailed
    end

    def self.open(
      root : String,
      ignores : Array(String),
      dirty_paths : DirtyPaths,
    ) : FSEvents | Problem
      case (resolved = Filesystem.realpath(root))
      in Problem
        Problem.new("the sync root could not be resolved: #{resolved.reason}")
      in String
        watcher = new(resolved, Scan::Ignores.new(ignores), dirty_paths)

        case watcher.started
        in Start::Running      then watcher
        in Start::CreateFailed then Problem.new("the FSEvents stream could not be created")
        in Start::StartFailed  then Problem.new("the FSEvents stream could not be started")
        in Nil                 then Problem.new("the watcher stopped before the stream started")
        end
      end
    end

    @started : Start? | Unresolved = Unresolved.new

    def initialize(@root : String, @ignores : Scan::Ignores, @dirty_paths : DirtyPaths) : Nil
      @prefix = "#{@root}/"
      @stopping = false
      @ready = Channel(Start).new
      @done = Channel(Nil).new
      @context = Fibers.isolated(:fs_events) { watch }
    end

    getter dirty_paths : DirtyPaths

    def started : Start?
      started = @started
      return started unless started.is_a?(Unresolved)

      @started = @ready.receive?
    end

    def close : Nil
      return if @stopping

      @stopping = true
      @done.receive?
    end

    protected def consume(count : LibC::SizeT, paths : UInt8**, flags : UInt32*) : Nil
      count.times do |index|
        flag = flags[index]

        if flag & FRESH_FLAGS != 0
          @dirty_paths.all_dirty!
          next
        end

        record(String.new(paths[index]).rstrip('/'), flag)
      end

      @dirty_paths.signal
    end

    private def record(path : String, flag : UInt32) : Nil
      relative = relativise(path)
      return if relative.nil?
      return if @ignores.ignore?(relative)

      @dirty_paths.add(relative)

      return unless flag & LibFSEvents::ITEM_IS_DIR != 0
      return unless flag & (LibFSEvents::ITEM_CREATED | LibFSEvents::ITEM_RENAMED) != 0

      @dirty_paths.add_tree(@root, relative, @ignores)
    end

    private def relativise(path : String) : String?
      return "" if path == @root
      return unless path.starts_with?(@prefix)

      path[@prefix.size..]
    end

    private def watch : Nil
      cf_root = LibFSEvents.string_create(nil, @root.check_no_null_byte, LibFSEvents::UTF8)
      roots = [cf_root]
      cf_paths = LibFSEvents.array_create(nil, roots.to_unsafe, 1, nil)

      boxed = Box.box(self)
      context = LibFSEvents::Context.new
      context.info = boxed

      stream = LibFSEvents.stream_create(
        nil,
        CALLBACK,
        pointerof(context),
        cf_paths,
        LibFSEvents::SINCE_NOW,
        LATENCY_SECONDS,
        LibFSEvents::CREATE_NO_DEFER | LibFSEvents::CREATE_FILE_EVENTS,
      )

      if stream.null?
        release(cf_paths, cf_root)
        @ready.send(Start::CreateFailed)
        return
      end

      LibFSEvents.stream_schedule(
        stream,
        LibFSEvents.run_loop_current,
        LibFSEvents.kCFRunLoopDefaultMode,
      )

      if LibFSEvents.stream_start(stream).zero?
        LibFSEvents.stream_invalidate(stream)
        LibFSEvents.stream_release(stream)
        release(cf_paths, cf_root)
        @ready.send(Start::StartFailed)
        return
      end

      @ready.send(Start::Running)

      until @stopping
        LibFSEvents.run_loop_run_in_mode(LibFSEvents.kCFRunLoopDefaultMode, STOP_POLL_SECONDS, 0_u8)
      end

      LibFSEvents.stream_stop(stream)
      LibFSEvents.stream_invalidate(stream)
      LibFSEvents.stream_release(stream)
      release(cf_paths, cf_root)
    ensure
      @done.close
    end

    private def release(*references : LibFSEvents::CFRef) : Nil
      references.each { |reference| LibFSEvents.release(reference) }
    end

    private record Unresolved
  end
end
