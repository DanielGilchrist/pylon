require "../platform"
require "../problem"

module Pylon::Scan
  struct Metadata
    NANOSECONDS_PER_SECOND = 1_000_000_000_i64
    GRANULARITY_NS         = 1_000_000_000_i64

    enum Kind
      Directory
      File
      SymbolicLink
      Untracked

      def self.from_mode(mode : UInt32) : Kind
        case mode & LibC::S_IFMT
        when LibC::S_IFREG then Kind::File
        when LibC::S_IFDIR then Kind::Directory
        when LibC::S_IFLNK then Kind::SymbolicLink
        else                    Kind::Untracked
        end
      end
    end

    def self.of(path : String) : Metadata | Problem | Nil
      stat = uninitialized LibC::Stat
      return from(stat) if LibC.lstat(path.check_no_null_byte, pointerof(stat)) == 0

      case (errno = Errno.value)
      when Errno::ENOENT, Errno::ENOTDIR
        nil
      else
        Problem.new("could not be examined (#{errno})")
      end
    end

    def self.from(stat : LibC::Stat) : Metadata
      timespec = modified_at(stat)

      new(
        mode: stat.st_mode.to_u32,
        size: stat.st_size.to_u64,
        mtime_ns: timespec.tv_sec.to_i64 * NANOSECONDS_PER_SECOND + timespec.tv_nsec.to_i64,
        inode: stat.st_ino.to_u64,
      )
    end

    private def self.modified_at(stat : LibC::Stat) : LibC::Timespec
      Platform.select do
        macos { stat.st_mtimespec }
        linux { stat.st_mtim }
      end
    end

    def initialize(@mode : UInt32, @size : UInt64, @mtime_ns : Int64, @inode : UInt64) : Nil
    end

    getter mode : UInt32
    getter size : UInt64
    getter mtime_ns : Int64
    getter inode : UInt64

    def kind : Kind
      Kind.from_mode(mode)
    end

    def executable? : Bool
      mode & 0o111_u32 != 0
    end

    def type_bits : UInt32
      mode & LibC::S_IFMT
    end

    def same_content?(other : Metadata) : Bool
      type_bits == other.type_bits &&
        mtime_ns == other.mtime_ns &&
        size == other.size &&
        inode == other.inode
    end

    def reusable?(other : Metadata) : Bool
      same_content?(other) && mode == other.mode
    end

    def freshly_modified?(now_ns : Int64, granularity_ns : Int64) : Bool
      now_ns - mtime_ns < granularity_ns
    end
  end
end
