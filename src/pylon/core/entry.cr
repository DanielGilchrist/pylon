module Pylon::Core
  struct Directory
    getter contents : Hash(String, Entry)
    getter? contains_problematic : Bool

    def initialize(contents : Hash(String, V) = Hash(String, Entry).new) forall V
      if contents.is_a?(Hash(String, Entry))
        @contents = contents
      else
        widened = Hash(String, Entry).new(initial_capacity: contents.size)
        contents.each { |name, child| widened[name] = child }
        @contents = widened
      end

      @contains_problematic = Directory.contains_problematic?(@contents)
    end

    protected def self.contains_problematic?(contents : Hash(String, Entry)) : Bool
      contents.each_value do |child|
        case child
        in Problematic
          return true
        in Directory
          return true if child.contains_problematic?
        in File, SymbolicLink, Untracked
        end
      end

      false
    end

    def syncable : Directory
      return self if contents.empty?

      retained = nil

      contents.each do |name, child|
        kept = child.syncable

        if kept.nil? || kept != child
          retained ||= carry_forward(name)
        end

        if (retained_contents = retained) && !kept.nil?
          retained_contents[name] = kept
        end
      end

      retained.nil? ? self : Directory.new(retained)
    end

    private def carry_forward(stop_at : String) : Hash(String, Entry)
      carried = {} of String => Entry

      contents.each do |name, child|
        break if name == stop_at

        carried[name] = child
      end

      carried
    end
  end

  struct File
    getter digest : Bytes

    def initialize(@digest : Bytes, @executable : Bool = false)
    end

    def executable? : Bool
      @executable
    end

    def syncable : File
      self
    end
  end

  struct SymbolicLink
    getter target : String

    def initialize(@target : String)
    end

    def syncable : SymbolicLink
      self
    end
  end

  struct Untracked
    def syncable : Nil
      nil
    end
  end

  struct Problematic
    getter problem : String

    def initialize(@problem : String)
    end

    def syncable : Nil
      nil
    end
  end

  alias Syncable = Directory | File | SymbolicLink
  alias Entry = Syncable | Untracked | Problematic
end
