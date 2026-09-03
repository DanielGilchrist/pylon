module Pylon::Core
  alias Syncable = Directory | File | SymbolicLink
  alias Entry = Syncable | Untracked | Problematic

  struct Directory
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

    def initialize(contents : Hash(String, V) = Hash(String, Entry).new) : Nil forall V
      if contents.is_a?(Hash(String, Entry))
        @contents = contents
      else
        widened = Hash(String, Entry).new(initial_capacity: contents.size)
        contents.each { |name, child| widened[name] = child }
        @contents = widened
      end

      @contains_problematic = Directory.contains_problematic?(@contents)
    end

    getter contents : Hash(String, Entry)
    getter? contains_problematic : Bool

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
      carried = Hash(String, Entry).new

      contents.each do |name, child|
        break if name == stop_at

        carried[name] = child
      end

      carried
    end
  end

  struct File
    def initialize(@digest : Bytes, @executable : Bool = false) : Nil
    end

    getter digest : Bytes

    def executable? : Bool
      @executable
    end

    def syncable : File
      self
    end
  end

  struct SymbolicLink
    def initialize(@target : String) : Nil
    end

    getter target : String

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
    def initialize(@problem : String) : Nil
    end

    getter problem : String

    def syncable : Nil
      nil
    end
  end
end
