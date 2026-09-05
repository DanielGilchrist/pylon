require "./change"
require "./paths"

module Pylon::Core
  struct Changes
    include Indexable(Change)

    def self.flatten(reconciled : Indexable(Change)) : Changes
      Changes.new(initial_capacity: reconciled.size).tap do |expanded|
        reconciled.each { |change| widen(change.path, change.old, change.new, expanded) }
      end
    end

    def self.[](*changes : Change) : Changes
      collected = new(initial_capacity: changes.size)
      changes.each { |change| collected << change }
      collected
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

    def initialize : Nil
      @changes = Array(Change).new
    end

    def initialize(*, initial_capacity : Int32) : Nil
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

    def ordered_for_writing(deferred : Set(Bytes)) : Changes
      leading = case_colliding_delete_indexes

      Changes.new(initial_capacity: size).tap do |ordered|
        leading.each { |index| ordered << @changes[index] }
        @changes.each do |change|
          ordered << change unless change.new.nil? || deferred?(change, deferred)
        end
        @changes.each { |change| ordered << change if deferred?(change, deferred) }

        @changes.each_with_index do |change, index|
          next unless change.new.nil?
          next if leading.includes?(index)

          ordered << change
        end
      end
    end

    def subtract_case_collision_digests(holds : Set(Bytes)) : Nil
      case_colliding_delete_indexes.each do |index|
        old = @changes[index].old
        holds.delete(old.digest) if old.is_a?(File)
      end
    end

    def case_colliding_delete_indexes : Set(Int32)
      survivors = nil
      colliding = Set(Int32).new

      @changes.each_with_index do |change, index|
        next unless change.new.nil?

        survivors ||= surviving_folded_paths
        colliding << index if survivors.includes?(change.path.downcase)
      end

      colliding
    end

    private def surviving_folded_paths : Set(String)
      folded = Set(String).new

      @changes.each do |change|
        folded << change.path.downcase unless change.new.nil?
      end

      folded
    end

    private def deferred?(change : Change, deferred : Set(Bytes)) : Bool
      return false if deferred.empty?

      entry = change.new
      entry.is_a?(File) && deferred.includes?(entry.digest)
    end
  end
end
