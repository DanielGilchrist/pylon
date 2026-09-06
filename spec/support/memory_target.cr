require "digest/sha256"
require "sync"
require "../../src/pylon/scan/metadata"
require "../../src/pylon/scan/observed"
require "../../src/pylon/problem"

private alias Metadata = Pylon::Scan::Metadata
private alias Missing = Pylon::Missing
private alias Problem = Pylon::Problem

class MemoryTarget
  record Node,
    kind : Pylon::Scan::Metadata::Kind,
    content : Bytes = Bytes.empty,
    target : String = "",
    executable : Bool = false,
    inode : UInt64 = 0_u64,
    mtime_ns : Int64 = 0_i64

  def initialize(@nodes = {"" => Node.new(kind: Pylon::Scan::Metadata::Kind::Directory)}) : Nil
    @next_inode = 100_u64
    @lock = Sync::Mutex.new
  end

  getter operations = Array(String).new
  getter nodes : Hash(String, Node)
  property? writable = true
  property? renamable = true

  def metadata(path : String) : Metadata?
    node = @lock.synchronize { @nodes[path]? }
    return if node.nil?

    metadata_for(node)
  end

  def observe(path : String) : Pylon::Scan::Observed | Problem | Nil
    node = @lock.synchronize { @nodes[path]? }
    return if node.nil?

    case node.kind
    in Pylon::Scan::Metadata::Kind::Directory then Pylon::Scan::ObservedDirectory.new
    in Pylon::Scan::Metadata::Kind::File
      Pylon::Scan::ObservedFile.new(metadata_for(node))
    in Pylon::Scan::Metadata::Kind::SymbolicLink then Pylon::Scan::ObservedLink.new(node.target)
    in Pylon::Scan::Metadata::Kind::Untracked    then Pylon::Scan::ObservedUntracked.new
    end
  end

  def digest(path : String) : Bytes | Problem
    node = @lock.synchronize { @nodes[path]? }
    return Problem.new("the file vanished after the scan saw it") if node.nil?

    Digest::SHA256.digest(node.content)
  end

  def each_child(path : String, & : String ->) : Missing | Problem | Nil
    names = @lock.synchronize { children_of(path) }
    return Missing.new if names.nil?

    names.each { |name| yield name }
    nil
  end

  def create_directory(path : String) : Problem?
    return read_only unless writable?

    @lock.synchronize do
      operations << "mkdir #{path}"
      @nodes[path] = Node.new(kind: Pylon::Scan::Metadata::Kind::Directory, inode: take_inode)
    end

    nil
  end

  def write_file(path : String, content : Bytes, executable : Bool) : Problem?
    return read_only unless writable?

    @lock.synchronize do
      operations << "write #{path}"
      @nodes[path] = Node.new(
        kind: Pylon::Scan::Metadata::Kind::File,
        content: content,
        executable: executable,
        inode: take_inode,
        mtime_ns: 5_000_i64,
      )
    end

    nil
  end

  def create_symlink(path : String, target : String) : Problem?
    return read_only unless writable?

    @lock.synchronize do
      operations << "symlink #{path}"
      @nodes[path] = Node.new(
        kind: Pylon::Scan::Metadata::Kind::SymbolicLink,
        target: target,
        inode: take_inode,
      )
    end

    nil
  end

  def set_executable(path : String, executable : Bool) : Problem?
    @lock.synchronize do
      node = @nodes[path]?
      return Problem.new("no such file") if node.nil?
      return read_only unless writable?

      operations << "chmod #{path}"
      @nodes[path] = node.copy_with(executable: executable)
    end

    nil
  end

  def rename(from : String, to : String) : Problem?
    return read_only unless writable?
    return Problem.new("Cross-device link") unless renamable?

    @lock.synchronize do
      operations << "rename #{from} #{to}"
      prefix = "#{from}/"
      moved = @nodes.select { |key, _| key == from || key.starts_with?(prefix) }
      moved.each_key { |key| @nodes.delete(key) }
      moved.each { |key, node| @nodes[key == from ? to : "#{to}#{key[from.size..]}"] = node }
    end

    nil
  end

  def remove(path : String) : Problem?
    return read_only unless writable?

    @lock.synchronize do
      operations << "remove #{path}"
      prefix = "#{path}/"
      @nodes.reject! { |key, _| key == path || key.starts_with?(prefix) }
    end

    nil
  end

  def seed_file(
    path : String,
    content : String,
    executable = false,
    inode = 1_u64,
    mtime_ns = 1_000_i64,
  ) : Bytes
    bytes = content.to_slice
    @nodes[path] = Node.new(
      kind: Pylon::Scan::Metadata::Kind::File,
      content: bytes,
      executable: executable,
      inode: inode,
      mtime_ns: mtime_ns,
    )
    Digest::SHA256.digest(bytes)
  end

  def seed_directory(path : String) : Nil
    @nodes[path] = Node.new(kind: Pylon::Scan::Metadata::Kind::Directory, inode: take_inode)
  end

  private def metadata_for(node : Node) : Metadata
    mode =
      case node.kind
      in Pylon::Scan::Metadata::Kind::Directory then LibC::S_IFDIR | 0o755
      in Pylon::Scan::Metadata::Kind::File
        LibC::S_IFREG | (node.executable ? 0o755 : 0o644)
      in Pylon::Scan::Metadata::Kind::SymbolicLink then LibC::S_IFLNK | 0o777
      in Pylon::Scan::Metadata::Kind::Untracked    then LibC::S_IFIFO | 0o644
      end

    Metadata.new(
      mode: mode.to_u32,
      size: node.content.size.to_u64,
      mtime_ns: node.mtime_ns,
      inode: node.inode,
    )
  end

  private def children_of(path : String) : Array(String)?
    return if @nodes[path]?.nil?

    prefix = path.empty? ? "" : "#{path}/"
    names = Array(String).new

    @nodes.each_key do |key|
      next if key == path || !key.starts_with?(prefix)

      name = key[prefix.size..]
      next if name.empty? || name.includes?('/')

      names << name
    end

    names
  end

  private def read_only : Problem
    Problem.new("the target is read-only")
  end

  private def take_inode : UInt64
    @next_inode += 1
  end
end

class MemoryStaging
  def initialize(@contents = Hash(Bytes, Bytes).new) : Nil
  end

  def add(content : String) : Bytes
    bytes = content.to_slice
    digest = Digest::SHA256.digest(bytes)
    @contents[digest] = bytes
    digest
  end

  def content(digest : Bytes, path : String) : Bytes?
    @contents[digest]?
  end
end
