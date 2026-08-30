require "digest/sha256"
require "../../src/pylon/scan/metadata"
require "../../src/pylon/write/problem"

class MemoryTarget
  record Node,
    kind : Pylon::Core::Entry::Kind,
    content : Bytes = Bytes.empty,
    target : String = "",
    executable : Bool = false,
    inode : UInt64 = 0_u64,
    mtime_ns : Int64 = 0_i64

  getter operations = [] of String
  getter nodes : Hash(String, Node)
  property? writable = true

  def initialize(@nodes = {"" => Node.new(kind: Pylon::Core::Entry::Kind::Directory)})
    @next_inode = 100_u64
  end

  def metadata(path : String) : Pylon::Scan::Metadata?
    node = @nodes[path]?
    return nil if node.nil?

    mode =
      case node.kind
      in Pylon::Core::Entry::Kind::Directory    then LibC::S_IFDIR | 0o755
      in Pylon::Core::Entry::Kind::File         then LibC::S_IFREG | (node.executable ? 0o755 : 0o644)
      in Pylon::Core::Entry::Kind::SymbolicLink then LibC::S_IFLNK | 0o777
      in Pylon::Core::Entry::Kind::Untracked    then LibC::S_IFIFO | 0o644
      in Pylon::Core::Entry::Kind::Problematic  then LibC::S_IFREG | 0o644
      end

    Pylon::Scan::Metadata.new(
      mode: mode.to_u32,
      size: node.content.size.to_u64,
      mtime_ns: node.mtime_ns,
      inode: node.inode,
    )
  end

  def create_directory(path : String) : Pylon::Write::Problem?
    return read_only unless writable?

    operations << "mkdir #{path}"
    @nodes[path] = Node.new(kind: Pylon::Core::Entry::Kind::Directory, inode: take_inode)
    nil
  end

  def write_file(path : String, content : Bytes, executable : Bool) : Pylon::Write::Problem?
    return read_only unless writable?

    operations << "write #{path}"
    @nodes[path] = Node.new(
      kind: Pylon::Core::Entry::Kind::File,
      content: content,
      executable: executable,
      inode: take_inode,
      mtime_ns: 5_000_i64,
    )
    nil
  end

  def create_symlink(path : String, target : String) : Pylon::Write::Problem?
    return read_only unless writable?

    operations << "symlink #{path}"
    @nodes[path] = Node.new(kind: Pylon::Core::Entry::Kind::SymbolicLink, target: target, inode: take_inode)
    nil
  end

  def set_executable(path : String, executable : Bool) : Pylon::Write::Problem?
    node = @nodes[path]?
    return Pylon::Write::Problem.new("no such file") if node.nil?
    return read_only unless writable?

    operations << "chmod #{path}"
    @nodes[path] = node.copy_with(executable: executable)
    nil
  end

  def remove(path : String) : Pylon::Write::Problem?
    return read_only unless writable?

    operations << "remove #{path}"
    prefix = "#{path}/"
    @nodes.reject! { |key, _| key == path || key.starts_with?(prefix) }
    nil
  end

  def seed_file(path : String, content : String, executable = false, inode = 1_u64, mtime_ns = 1_000_i64) : Bytes
    bytes = content.to_slice
    @nodes[path] = Node.new(
      kind: Pylon::Core::Entry::Kind::File,
      content: bytes,
      executable: executable,
      inode: inode,
      mtime_ns: mtime_ns,
    )
    Digest::SHA256.digest(bytes)
  end

  def seed_directory(path : String) : Nil
    @nodes[path] = Node.new(kind: Pylon::Core::Entry::Kind::Directory, inode: take_inode)
  end

  private def read_only : Pylon::Write::Problem
    Pylon::Write::Problem.new("the target is read-only")
  end

  private def take_inode : UInt64
    @next_inode += 1
  end
end

class MemoryStaging
  def initialize(@contents = {} of Bytes => Bytes)
  end

  def add(content : String) : Bytes
    bytes = content.to_slice
    digest = Digest::SHA256.digest(bytes)
    @contents[digest] = bytes
    digest
  end

  def content(digest : Bytes) : Bytes?
    @contents[digest]?
  end
end
