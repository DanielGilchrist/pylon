module Pylon::Core
  struct Directory
    getter contents : Hash(String, Entry)

    def initialize(contents : Hash(String, V) = Hash(String, Entry).new) forall V
      if contents.is_a?(Hash(String, Entry))
        @contents = contents
      else
        widened = Hash(String, Entry).new(initial_capacity: contents.size)
        contents.each { |name, child| widened[name] = child }
        @contents = widened
      end
    end

    def synchronizable? : Bool
      true
    end

    def synchronizable : Entry?
      return self if contents.empty?

      retained = nil

      contents.each do |name, child|
        kept = child.synchronizable

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

    def synchronizable? : Bool
      true
    end

    def synchronizable : Entry?
      self
    end
  end

  struct SymbolicLink
    getter target : String

    def initialize(@target : String)
    end

    def synchronizable? : Bool
      true
    end

    def synchronizable : Entry?
      self
    end
  end

  struct Untracked
    def synchronizable? : Bool
      false
    end

    def synchronizable : Entry?
      nil
    end
  end

  struct Problematic
    getter problem : String

    def initialize(@problem : String)
    end

    def synchronizable? : Bool
      false
    end

    def synchronizable : Entry?
      nil
    end
  end

  alias Entry = Directory | File | SymbolicLink | Untracked | Problematic
end
