module Pylon::Core
  struct Entry
    enum Kind
      Directory
      File
      SymbolicLink
      Untracked
      Problematic

      def self.from_mode(mode : UInt32) : Kind
        case mode & LibC::S_IFMT
        when LibC::S_IFREG then Kind::File
        when LibC::S_IFDIR then Kind::Directory
        when LibC::S_IFLNK then Kind::SymbolicLink
        else                    Kind::Untracked
        end
      end

      def synchronizable? : Bool
        directory? || file? || symbolic_link?
      end
    end

    private EMPTY_CONTENTS = {} of String => Entry

    def self.equal?(left : Entry?, right : Entry?) : Bool
      return true if left.nil? && right.nil?
      return false if left.nil? || right.nil?

      left.equal?(right)
    end

    def self.synchronizable(entry : Entry?) : Entry?
      return nil if entry.nil?
      return nil unless entry.synchronizable?
      return entry unless entry.directory?

      contents = entry.contents
      return entry if contents.empty?

      retained = nil

      contents.each do |name, child|
        kept = synchronizable(child)

        if kept.nil? || !kept.equal?(child)
          retained ||= carry_forward(contents, name)
        end

        if (retained_contents = retained) && !kept.nil?
          retained_contents[name] = kept
        end
      end

      retained.nil? ? entry : entry.with_contents(retained)
    end

    private def self.carry_forward(contents : Hash(String, Entry), stop_at : String) : Hash(String, Entry)
      carried = {} of String => Entry

      contents.each do |name, child|
        break if name == stop_at

        carried[name] = child
      end

      carried
    end

    def self.directory(contents : Hash(String, Entry)? = nil) : Entry
      new(kind: Kind::Directory, contents: contents)
    end

    def self.file(digest : Bytes, executable : Bool = false) : Entry
      new(kind: Kind::File, digest: digest, executable: executable)
    end

    def self.symlink(target : String) : Entry
      new(kind: Kind::SymbolicLink, target: target)
    end

    def self.untracked : Entry
      new(kind: Kind::Untracked)
    end

    def self.problematic(problem : String) : Entry
      new(kind: Kind::Problematic, problem: problem)
    end

    getter kind : Kind
    getter digest : Bytes?
    getter target : String?
    getter problem : String?

    def initialize(
      @kind : Kind,
      @digest : Bytes? = nil,
      @executable : Bool = false,
      @target : String? = nil,
      @problem : String? = nil,
      @contents : Hash(String, Entry)? = nil,
    )
    end

    def executable? : Bool
      @executable
    end

    def contents : Hash(String, Entry)
      @contents || EMPTY_CONTENTS
    end

    def synchronizable? : Bool
      kind.synchronizable?
    end

    def untracked? : Bool
      kind.untracked?
    end

    def problematic? : Bool
      kind.problematic?
    end

    def directory? : Bool
      kind.directory?
    end

    def with_contents(contents : Hash(String, Entry)) : Entry
      Entry.new(
        kind: kind,
        digest: digest,
        executable: executable?,
        target: target,
        problem: problem,
        contents: contents,
      )
    end

    def equal?(other : Entry) : Bool
      return false unless kind == other.kind
      return false unless digest == other.digest
      return false unless executable? == other.executable?
      return false unless target == other.target
      return false unless problem == other.problem
      return false unless contents.size == other.contents.size

      contents.all? do |name, child|
        if (other_child = other.contents[name]?)
          child.equal?(other_child)
        else
          false
        end
      end
    end

    def contains_unsynchronizable? : Bool
      return true unless synchronizable?

      contents.each_value.any?(&.contains_unsynchronizable?)
    end
  end
end
