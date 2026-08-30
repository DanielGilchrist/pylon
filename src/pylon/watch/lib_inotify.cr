{% skip_file unless flag?(:linux) %}

lib LibInotify
  IN_MODIFY      = 0x00000002_u32
  IN_ATTRIB      = 0x00000004_u32
  IN_CLOSE_WRITE = 0x00000008_u32
  IN_MOVED_FROM  = 0x00000040_u32
  IN_MOVED_TO    = 0x00000080_u32
  IN_CREATE      = 0x00000100_u32
  IN_DELETE      = 0x00000200_u32
  IN_DELETE_SELF = 0x00000400_u32
  IN_MOVE_SELF   = 0x00000800_u32
  IN_Q_OVERFLOW  = 0x00004000_u32
  IN_IGNORED     = 0x00008000_u32
  IN_ONLYDIR     = 0x01000000_u32
  IN_EXCL_UNLINK = 0x04000000_u32
  IN_ISDIR       = 0x40000000_u32

  IN_NONBLOCK = 0x00000800
  IN_CLOEXEC  = 0x00080000

  POLLIN = 1_i16

  struct Event
    wd : Int32
    mask : UInt32
    cookie : UInt32
    len : UInt32
  end

  struct PollDescriptor
    fd : LibC::Int
    events : LibC::Short
    revents : LibC::Short
  end

  fun inotify_init1(flags : Int32) : Int32
  fun inotify_add_watch(fd : Int32, pathname : UInt8*, mask : UInt32) : Int32
  fun poll(descriptors : PollDescriptor*, count : LibC::ULong, timeout_ms : LibC::Int) : LibC::Int
end
