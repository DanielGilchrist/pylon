require "digest/sha256"
require "../../src/pylon/scan/metadata"

struct MemoryFilesystem
  record Node,
    kind : Pylon::Core::Entry::Kind,
    content : String = "",
    target : String = "",
    executable : Bool = false,
    inode : UInt64 = 0_u64,
    mtime_ns : Int64 = 0_i64,
    readable : Bool = true

  getter reads = [] of String

  def initialize(@nodes : Hash(String, Node))
  end

  def self.build(files : Hash(String, String)) : MemoryFilesystem
    nodes = {"" => Node.new(kind: Pylon::Core::Entry::Kind::Directory)}
    inode = 1_u64

    files.each do |path, content|
      parts = path.split('/')

      parts.each_index do |index|
        next if index == parts.size - 1

        directory = parts[0, index + 1].join('/')
        nodes[directory] ||= Node.new(kind: Pylon::Core::Entry::Kind::Directory)
      end

      nodes[path] = Node.new(
        kind: Pylon::Core::Entry::Kind::File,
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

  def metadata(relative_path : String) : Pylon::Scan::Metadata?
    node = @nodes[relative_path]?
    return nil if node.nil?

    mode = case node.kind
           in Pylon::Core::Entry::Kind::Directory    then LibC::S_IFDIR | 0o755
           in Pylon::Core::Entry::Kind::File         then LibC::S_IFREG | (node.executable ? 0o755 : 0o644)
           in Pylon::Core::Entry::Kind::SymbolicLink then LibC::S_IFLNK | 0o777
           in Pylon::Core::Entry::Kind::Untracked    then LibC::S_IFIFO | 0o644
           in Pylon::Core::Entry::Kind::Problematic  then LibC::S_IFREG | 0o644
           end

    Pylon::Scan::Metadata.new(
      mode: mode.to_u32,
      size: node.content.bytesize.to_u64,
      mtime_ns: node.mtime_ns,
      inode: node.inode,
    )
  end

  def each_child(relative_path : String, & : String ->) : Nil
    prefix = relative_path.empty? ? "" : "#{relative_path}/"

    @nodes.each_key do |path|
      next if path.empty? || !path.starts_with?(prefix)

      remainder = path[prefix.bytesize..]
      next if remainder.empty? || remainder.includes?('/')

      yield remainder
    end
  end

  def digest(relative_path : String) : Bytes?
    node = @nodes[relative_path]
    return nil unless node.readable

    reads << relative_path
    Digest::SHA256.digest(node.content)
  end

  def link_target(relative_path : String) : String?
    @nodes[relative_path].target
  end
end
