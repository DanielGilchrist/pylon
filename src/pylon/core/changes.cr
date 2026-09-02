require "./change"
require "./paths"

module Pylon::Core
  struct Changes
    include Indexable(Change)

    def self.expand(reconciled : Indexable(Change)) : Changes
      Changes.new(initial_capacity: reconciled.size).tap do |expanded|
        reconciled.each { |change| widen(change.path, change.old, change.new, expanded) }
      end
    end

    private def self.widen(path : String, old : Entry?, new : Entry?, into : Changes) : Nil
      if !new.is_a?(Directory) || new.contents.empty?
        into << Change.new(path, old, new)
        return
      end

      into << Change.new(path, old, Directory.new)

      new.contents.each do |name, child|
        widen(Paths.join(path, name), nil, child, into)
      end
    end

    def initialize
      @changes = [] of Change
    end

    def self.[](*changes : Change) : Changes
      collected = new(initial_capacity: changes.size)
      changes.each { |change| collected << change }
      collected
    end

    def initialize(*, initial_capacity : Int32)
      @changes = Array(Change).new(initial_capacity)
    end

    def size : Int32
      @changes.size
    end

    def unsafe_fetch(index : Int) : Change
      @changes.unsafe_fetch(index)
    end

    def <<(change : Change) : self
      @changes << change
      self
    end

    def clear : self
      @changes.clear
      self
    end

    def each(*, within range : Range, & : Change ->) : Nil
      @changes.each(within: range) { |change| yield change }
    end

    def batch(offset : Int32, count : Int32) : Changes
      taken = Changes.new(initial_capacity: count)
      @changes.each(within: offset...(offset + count)) { |change| taken << change }
      taken
    end

    def +(other : Changes) : Changes
      combined = Changes.new(initial_capacity: size + other.size)
      each { |change| combined << change }
      other.each { |change| combined << change }
      combined
    end

    def deletes_last(late : Set(Bytes)) : Changes
      Changes.new(initial_capacity: size).tap do |ordered|
        @changes.each { |change| ordered << change unless change.new.nil? || late?(change, late) }
        @changes.each { |change| ordered << change if late?(change, late) }
        @changes.each { |change| ordered << change if change.new.nil? }
      end
    end

    private def late?(change : Change, late : Set(Bytes)) : Bool
      return false if late.empty?

      entry = change.new
      entry.is_a?(File) && late.includes?(entry.digest)
    end
  end
end
