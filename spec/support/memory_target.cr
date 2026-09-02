require "digest/sha256"
require "../../src/pylon/scan/metadata"
require "../../src/pylon/scan/observed"
require "../../src/pylon/write/problem"

class MemoryTarget
  record Node,
    kind : Pylon::Scan::Metadata::Kind,
    content : Bytes = Bytes.empty,
    target : String = "",
    executable : Bool = false,
    inode : UInt64 = 0_u64,
    mtime_ns : Int64 = 0_i64

  getter operations = [] of String
  getter nodes : Hash(String, Node)
  property? writable = true

  def initialize(@nodes = {"" => Node.new(kind: Pylon::Scan::Metadata::Kind::Directory)})
    @next_inode = 100_u64
  end

  def metadata(path : String) : Pylon::Scan::Metadata?
    node = @nodes[path]?
    return if node.nil?

    mode =
      case node.kind
      in Pylon::Scan::Metadata::Kind::Directory    then LibC::S_IFDIR | 0o755
      in Pylon::Scan::Metadata::Kind::File         then LibC::S_IFREG | (node.executable ? 0o755 : 0o644)
      in Pylon::Scan::Metadata::Kind::SymbolicLink then LibC::S_IFLNK | 0o777
      in Pylon::Scan::Metadata::Kind::Untracked    then LibC::S_IFIFO | 0o644
      end

    Pylon::Scan::Metadata.new(
      mode: mode.to_u32,
      size: node.content.size.to_u64,
      mtime_ns: node.mtime_ns,
      inode: node.inode,
    )
  end

  def observe(path : String) : Pylon::Scan::Observed | Pylon::Write::Problem | Nil
    node = @nodes[path]?
    return if node.nil?

    case node.kind
    in Pylon::Scan::Metadata::Kind::Directory    then Pylon::Scan::ObservedDirectory.new
    in Pylon::Scan::Metadata::Kind::File         then Pylon::Scan::ObservedFile.new(metadata(path).not_nil!)
    in Pylon::Scan::Metadata::Kind::SymbolicLink then Pylon::Scan::ObservedLink.new(node.target)
    in Pylon::Scan::Metadata::Kind::Untracked    then Pylon::Scan::ObservedUntracked.new
    end
  end

  def digest(path : String) : Bytes | Pylon::Problem
    node = @nodes[path]?
    return Pylon::Problem.new("the file vanished after the scan saw it") if node.nil?

    Digest::SHA256.digest(node.content)
  end

  def each_child(path : String, & : String ->) : Pylon::Missing | Pylon::Problem | Nil
    node = @nodes[path]?
    return Pylon::Missing.new if node.nil?

    prefix = path.empty? ? "" : "#{path}/"

    @nodes.each_key do |key|
      next if key == path || !key.starts_with?(prefix)

      name = key[prefix.size..]
      next if name.empty? || name.includes?('/')

      yield name
    end

    nil
  end

  def create_directory(path : String) : Pylon::Write::Problem?
    return read_only unless writable?

    operations << "mkdir #{path}"
    @nodes[path] = Node.new(kind: Pylon::Scan::Metadata::Kind::Directory, inode: take_inode)
    nil
  end

  def write_file(path : String, content : Bytes, executable : Bool) : Pylon::Write::Problem?
    return read_only unless writable?

    operations << "write #{path}"
    @nodes[path] = Node.new(
      kind: Pylon::Scan::Metadata::Kind::File,
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
    @nodes[path] = Node.new(kind: Pylon::Scan::Metadata::Kind::SymbolicLink, target: target, inode: take_inode)
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
