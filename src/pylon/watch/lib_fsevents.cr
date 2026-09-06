Pylon::Platform.skip_file_unless :macos

@[Link(framework: "CoreFoundation")]
@[Link(framework: "CoreServices")]
lib LibFSEvents
  alias CFIndex = Int64
  alias CFRef = Void*
  alias StreamRef = Void*

  alias Callback = StreamRef, Void*, LibC::SizeT, UInt8**, UInt32*, UInt64* ->

  UTF8 = 0x08000100_u32

  SINCE_NOW = 0xFFFFFFFFFFFFFFFF_u64

  CREATE_NO_DEFER    = 0x00000002_u32
  CREATE_FILE_EVENTS = 0x00000010_u32

  MUST_SCAN_SUBDIRS = 0x00000001_u32
  USER_DROPPED      = 0x00000002_u32
  KERNEL_DROPPED    = 0x00000004_u32
  IDS_WRAPPED       = 0x00000008_u32
  ROOT_CHANGED      = 0x00000020_u32
  ITEM_CREATED      = 0x00000100_u32
  ITEM_RENAMED      = 0x00000800_u32
  ITEM_IS_DIR       = 0x00020000_u32

  struct Context
    version : CFIndex
    info : Void*
    retain : Void*
    release : Void*
    copy_description : Void*
  end

  $kCFRunLoopDefaultMode : CFRef

  fun string_create = CFStringCreateWithCString(
    allocator : Void*,
    chars : UInt8*,
    encoding : UInt32,
  ) : CFRef
  fun array_create = CFArrayCreate(
    allocator : Void*,
    values : Void**,
    count : CFIndex,
    callbacks : Void*,
  ) : CFRef
  fun release = CFRelease(reference : CFRef)

  fun run_loop_current = CFRunLoopGetCurrent : CFRef
  fun run_loop_run_in_mode = CFRunLoopRunInMode(
    mode : CFRef,
    seconds : Float64,
    return_after_source : UInt8,
  ) : Int32
  fun run_loop_stop = CFRunLoopStop(run_loop : CFRef)

  fun stream_create = FSEventStreamCreate(
    allocator : Void*,
    callback : Callback,
    context : Context*,
    paths : CFRef,
    since : UInt64,
    latency : Float64,
    flags : UInt32,
  ) : StreamRef

  fun stream_schedule = FSEventStreamScheduleWithRunLoop(
    stream : StreamRef,
    run_loop : CFRef,
    mode : CFRef,
  )
  fun stream_start = FSEventStreamStart(stream : StreamRef) : UInt8
  fun stream_stop = FSEventStreamStop(stream : StreamRef)
  fun stream_invalidate = FSEventStreamInvalidate(stream : StreamRef)
  fun stream_release = FSEventStreamRelease(stream : StreamRef)
end
