require "digest/sha256"
require "../../src/pylon/scan/metadata"
require "../../src/pylon/problem"
require "../../src/pylon/filesystem"

struct MemoryFilesystem
  record Node,
    kind : Pylon::Scan::Metadata::Kind,
    content : String = "",
    target : String = "",
    executable : Bool = false,
    inode : UInt64 = 0_u64,
    mtime_ns : Int64 = 0_i64,
    readable : Bool = true,
    statable : Bool = true

  getter reads = [] of String

  def initialize(@nodes : Hash(String, Node))
  end

  def self.build(files : Hash(String, String)) : MemoryFilesystem
    nodes = {"" => Node.new(kind: Pylon::Scan::Metadata::Kind::Directory)}
    inode = 1_u64

    files.each do |path, content|
      parts = path.split('/')

      parts.each_index do |index|
        next if index == parts.size - 1

        directory = parts[0, index + 1].join('/')
        nodes[directory] ||= Node.new(kind: Pylon::Scan::Metadata::Kind::Directory)
      end

      nodes[path] = Node.new(
        kind: Pylon::Scan::Metadata::Kind::File,
        content: content,
        inode: inode,
        mtime_ns: 1_000_i64,
      )
      inode += 1
    end

    new(nodes)
  end

  def with(path : String, **changes) : MemoryFilesystem
    nodes = @nodes.dup
    nodes[path] = @nodes[path].copy_with(**changes)
    MemoryFilesystem.new(nodes)
  end

  def metadata(relative_path : String) : Pylon::Scan::Metadata | Pylon::Problem | Nil
    node = @nodes[relative_path]?
    return if node.nil?
    return Pylon::Problem.new("could not be examined (EACCES)") unless node.statable

    mode =
      case node.kind
      in Pylon::Scan::Metadata::Kind::Directory    then LibC::S_IFDIR | 0o755
      in Pylon::Scan::Metadata::Kind::File         then LibC::S_IFREG | (node.executable ? 0o755 : 0o644)
      in Pylon::Scan::Metadata::Kind::SymbolicLink then LibC::S_IFLNK | 0o777
      in Pylon::Scan::Metadata::Kind::Untracked    then LibC::S_IFIFO | 0o644
      end

    Pylon::Scan::Metadata.new(
      mode: mode.to_u32,
      size: node.content.bytesize.to_u64,
      mtime_ns: node.mtime_ns,
      inode: node.inode,
    )
  end

  def each_child(relative_path : String, & : String ->) : Pylon::Missing | Pylon::Problem | Nil
    prefix = relative_path.empty? ? "" : "#{relative_path}/"

    @nodes.each_key do |path|
      next if path.empty? || !path.starts_with?(prefix)

      remainder = path[prefix.bytesize..]
      next if remainder.empty? || remainder.includes?('/')

      yield remainder
    end

    nil
  end

  def digest(relative_path : String, buffer : Bytes = Bytes.empty, hasher : Digest::SHA256 = Digest::SHA256.new) : Bytes | Pylon::Problem
    node = @nodes[relative_path]
    return Pylon::Problem.new("could not be read (EACCES)") unless node.readable

    reads << relative_path
    Digest::SHA256.digest(node.content)
  end

  def link_target(relative_path : String) : String?
    @nodes[relative_path].target
  end
end
